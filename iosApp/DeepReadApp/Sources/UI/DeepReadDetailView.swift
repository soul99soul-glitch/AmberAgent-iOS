import SwiftUI

struct DeepReadDetailView: View {
    let taskId: String
    let settings: DeepReadSettingsStore
    let runtime: DeepReadRuntime
    @Environment(\.colorScheme) private var colorScheme
    @State private var html = ""
    @State private var error: String?
    @State private var exporting = false
    @State private var sheet: ReaderSheet?
    @State private var press: PressMoment?
    /// Nil follows the article: original when it has no guide yet, close reading otherwise.
    @State private var originalChoice: Bool?
    /// Decoded once per task change; the body and toolbar read it many times per update.
    @State private var closeReading: DeepReadCloseReading?
    @State private var isTemplateArticle = false
    private let templates = IOSDeepReadTemplateStore.shared
    @Bindable private var appearance = DeepReadAppearance.shared

    private enum ReaderSheet: Identifiable {
        case sources
        case share(URL)
        var id: String {
            switch self {
            case .sources: "sources"
            case .share(let url): url.absoluteString
            }
        }
    }

    private struct PressMoment: Equatable {
        let inscription: String
        let caption: String
    }

    private var task: IOSDeepReadTask? { runtime.store.task(id: taskId) }
    private var showsOriginal: Bool { closeReading.map { originalChoice ?? !$0.hasGuide } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if let task {
                statusPanel(task)
                if let error {
                    Text(error).font(.callout).foregroundStyle(DeepReadPalette.danger).padding().textSelection(.enabled)
                }
                if !html.isEmpty {
                    DeepReadArticleWebView(html: html, error: $error,
                        allowsRemoteImages: closeReading != nil || templates.template(id: task.templateId) == nil)
                        .accessibilityIdentifier("deepread.reader.article")
                        .transition(.opacity.combined(with: .offset(y: 24)))
                } else if task.status == .running || task.status == .queued {
                    DeepReadNewsroomView(title: task.title, progressLabel: runtime.store.progressLabel(for: task.id))
                        .transition(.opacity)
                } else {
                    ContentUnavailableView("文章尚未生成", systemImage: "doc.text", description: Text("检查来源与模型设置后重试。"))
                }
            } else {
                ContentUnavailableView("找不到这篇阅读", systemImage: "doc.questionmark")
            }
        }
        .animation(.easeOut(duration: 0.5), value: html.isEmpty)
        .background { DeepReadPaperBackground() }
        .overlay {
            if let press {
                DeepReadPressMoment(inscription: press.inscription, caption: press.caption)
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.easeOut) { self.press = nil } }
            }
        }
        .task(id: press) {
            guard let press else { return }
            // A replaced or dismissed seal cancels this task; don't clear its successor.
            guard (try? await Task.sleep(for: .seconds(press.inscription == "付印" ? 1.4 : 2.6))) != nil else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.press = nil }
        }
        .onChange(of: task) { old, new in
            guard let old, let new, old.status == .running || old.status == .queued, new.status == .succeeded,
                  let seal = DeepReadMoment.pressSeal(
                    finishedWithError: runtime.error(for: new.id) != nil,
                    wasFirstDraft: old.resultMarkdown.isEmpty,
                    completedCount: runtime.store.tasks.filter { $0.status == .succeeded }.count)
            else { return }
            withAnimation(.easeIn(duration: 0.2)) { press = PressMoment(inscription: seal.inscription, caption: seal.caption) }
        }
        .navigationTitle("深度阅读")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only a reading with AI content has two views to switch between.
            if let reading = closeReading, reading.hasGuide {
                ToolbarItem(placement: .principal) {
                    Picker("阅读方式", selection: Binding(get: { showsOriginal }, set: { originalChoice = $0 })) {
                        Text("精读").tag(false)
                        Text("原文").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // Custom HTML templates bring their own look, so styles only apply to built-ins.
                // Close reading always uses the built-in page and follows the original's order.
                if let task {
                    // Close readings and template syntheses have no magazine sections to reorder.
                    let isCloseReading = closeReading != nil || isTemplateArticle
                    if isCloseReading || templates.template(id: task.templateId) == nil {
                        Menu {
                            if !isCloseReading {
                                Picker("版式", selection: $appearance.readerLayout) {
                                    ForEach(DeepReadReaderLayout.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                            Picker("样式", selection: $appearance.readerStyle) {
                                ForEach(DeepReadReaderStyle.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.menu)
                        } label: { Label("版式与样式", systemImage: "textformat") }
                    }
                }
                if let task, let reading = closeReading, !reading.hasGuide, task.status == .succeeded {
                    Button("生成精读", systemImage: "sparkles") {
                        do { try runtime.annotate(taskId: task.id) } catch { self.error = IOSDeepReadUserFacingText.fromError(error) }
                    }
                }
                Button("来源", systemImage: "link") { sheet = .sources }
                Menu {
                    Button("文本") { export(.text) }
                    Button("Markdown") { export(.markdown) }
                    Button("PDF") { export(.pdf) }
                } label: {
                    if exporting { ProgressView() } else { Label("分享", systemImage: "square.and.arrow.up") }
                }.disabled(exporting || task?.resultMarkdown.isEmpty != false)
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .sources: NavigationStack { DeepReadSourcesView(sources: task?.sources ?? []) }
            case .share(let url): DeepReadActivitySheet(url: url)
            }
        }
        .onChange(of: task, initial: true) { _, task in
            closeReading = DeepReadCloseReading.decode(task?.structuredJSON)
            isTemplateArticle = closeReading == nil && DeepReadTemplateArticle.decode(task?.structuredJSON) != nil
            render()
        }
        .onChange(of: settings.fontScale) { _, _ in render() }
        .onChange(of: settings.fontMode) { _, _ in render() }
        .onChange(of: colorScheme) { _, _ in render() }
        .onChange(of: templates.templates) { _, _ in render() }
        .onChange(of: appearance.readerStyle) { _, _ in render() }
        .onChange(of: appearance.readerLayout) { _, _ in render() }
        .onChange(of: appearance.accent) { _, _ in render() }
        // Changes to closeReading already re-render in the task handler above.
        .onChange(of: originalChoice) { _, _ in render() }
        .sensoryFeedback(.selection, trigger: originalChoice)
        .sensoryFeedback(.selection, trigger: appearance.readerStyle)
        .sensoryFeedback(.selection, trigger: appearance.readerLayout)
    }

    @ViewBuilder
    private func statusPanel(_ task: IOSDeepReadTask) -> some View {
        let searchFailures = task.sources.filter { $0.metadata["search_query"] != nil && $0.metadata["scrape_status"] == "failed" }
        if task.status != .succeeded || !(task.missingSections ?? []).isEmpty || runtime.store.persistenceError(for: task.id) != nil || runtime.error(for: task.id) != nil || !searchFailures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if task.status == .running || task.status == .queued { ProgressView() }
                    Text(runtime.store.progressLabel(for: task.id) ?? (task.status == .succeeded && runtime.error(for: task.id) != nil ? "已保留原文" : task.status.title)).font(.subheadline.weight(.medium))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: runtime.store.progressLabel(for: task.id))
                    Spacer()
                    if runtime.activeTaskIds.contains(task.id) {
                        Button("取消") { runtime.cancel(taskId: task.id) }
                            .modifier(DeepReadTapTarget())
                    } else if task.status == .failed || task.status == .unsupported || !(task.missingSections ?? []).isEmpty || runtime.error(for: task.id) != nil || !searchFailures.isEmpty {
                        Button(!(task.missingSections ?? []).isEmpty ? "补全章节" : "重试") {
                            do { try runtime.retry(taskId: task.id); error = nil } catch { self.error = error.localizedDescription }
                        }
                        .modifier(DeepReadTapTarget())
                    }
                }
                if let failure = task.failureMessage { Text(failure).font(.footnote).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled) }
                if let failure = runtime.error(for: task.id), failure != task.failureMessage {
                    Text(failure).font(.footnote).foregroundStyle(DeepReadPalette.danger).textSelection(.enabled)
                }
                if let persistence = runtime.store.persistenceError(for: task.id) { Text(persistence).font(.footnote).foregroundStyle(DeepReadPalette.danger) }
                if !searchFailures.isEmpty {
                    Text("\(searchFailures.count) 个搜索角度未取得资料。可在“来源”中查看原因。")
                        .font(.footnote).foregroundStyle(DeepReadPalette.muted)
                }
                if let missing = task.missingSections, !missing.isEmpty {
                    Text("待补全：\(missing.joined(separator: "、"))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func render() {
        guard let task, !task.resultMarkdown.isEmpty || task.structuredJSON != nil else { html = ""; return }
        do {
            let rendered = try DeepReadArticleRenderer.html(task: task, settings: settings, dark: colorScheme == .dark, originalOnly: showsOriginal)
            if html != rendered {
                html = rendered
                error = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    private enum ExportFormat { case text, markdown, pdf }

    private func export(_ format: ExportFormat) {
        guard let task else { return }
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                let data: Data
                let suffix: String
                switch format {
                case .pdf:
                    // The PDF loads no remote images (CSP), so they are hidden instead of leaving empty frames.
                    let document = try DeepReadArticleRenderer.html(task: task, settings: settings, originalOnly: showsOriginal, forPrint: true)
                        .replacingOccurrences(of: "</head>", with: "<style>html,body{-webkit-print-color-adjust:exact;print-color-adjust:exact;}img,figure{display:none!important;}</style></head>")
                    data = try await IOSHTMLPDFRenderer.render(html: IOSHTMLPDFRenderer.printFriendly(document))
                    suffix = "pdf"
                case .markdown:
                    let body = task.resultMarkdown.hasPrefix("# ") ? task.resultMarkdown : "# \(task.title)\n\n\(task.resultMarkdown)"
                    data = Data(body.utf8)
                    suffix = "md"
                case .text:
                    let body = task.resultMarkdown.hasPrefix("# ") ? task.resultMarkdown : "# \(task.title)\n\n\(task.resultMarkdown)"
                    data = Data(DeepReadTextExporter.text(from: body).utf8)
                    suffix = "txt"
                }
                let url = try IOSShareFileWriter.write(data, fileName: task.title, pathExtension: suffix)
                sheet = .share(url)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DeepReadSourcesView: View {
    let sources: [IOSDeepReadSource]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Group {
                ForEach(sources) { source in
                    Section {
                        Text(source.title).font(.headline)
                        Text(source.kind.title).font(.caption).foregroundStyle(.secondary)
                        if let value = source.url, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Link(value, destination: url).font(.footnote).textSelection(.enabled)
                        }
                        if let status = source.metadata["scrape_status"] {
                            let label = source.metadata["search_query"] != nil && status == "failed"
                                ? "补充搜索失败"
                                : status == "ok" ? "已取得正文" : status == "failed" ? "正文抓取失败" : status
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = source.metadata["scrape_error"] { Text(failure).font(.footnote).foregroundStyle(DeepReadPalette.danger) }
                        DisclosureGroup("查看采集内容") { Text(source.content).font(.footnote).textSelection(.enabled) }
                    }
                }
            }
            .listRowBackground(DeepReadPalette.card)
        }
        .scrollContentBackground(.hidden)
        .background { DeepReadPaperBackground() }
        .navigationTitle("原始来源")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
