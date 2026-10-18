import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
@preconcurrency import WebKit
#endif
@preconcurrency import Network
@preconcurrency import Shared

extension BoardSignal: @retroactive @unchecked Sendable {}

private enum IOSHotListWiFiGate {
    static func isSatisfied() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                monitor.pathUpdateHandler = nil
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "app.amber.ios.hotlist-wifi-gate"))
        }
    }
}

struct BoardView: View {
    let settingsStore: SettingsStore
    let sharedSettings: IOSSharedSettingsStore
    var providerRegistry: ProviderRegistryStore? = nil

    @State private var generationState = BoardGenerationState.idle
    @State private var collectionSnapshot = IOSBoardCollectionSnapshot.empty
    @State private var deepReadStore = IOSDeepReadStore.shared
    @State private var hotListStore = IOSHotListDashboardStore.shared
    @State private var deepReadTitle = ""
    @State private var manualText = ""
    @State private var searchQuery = ""
    @State private var links = ""
    @State private var readingMode = ReadingMode.synthesis
    @State private var selectedTemplateId = IOSDeepReadTemplate.defaultId
    @State private var deepReadMessage: String?
    @State private var deepReadMessageIsError = false
    @State private var isCreatingDeepRead = false
    @State private var isImportingDeepReadFile = false
    @State private var showCustomSourceSheet = false
    @State private var showHistorySheet = false
    @State private var historyQuery = ""
    @State private var historyFilter = HistoryFilter.all
    @State private var topicActionTarget: IOSHotTopic?
    @State private var appliedBoardSettings: BoardSettingsSignature?
    @State private var hotListMessage: String?

    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(DocumentAccessStore.self) private var documentStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// A close reading takes exactly one source (text, link, file or page) as the article itself.
    private enum ReadingMode { case synthesis, closeReading, originalOnly }

    private var closeReadingIndex: Int? { readingMode == .synthesis ? nil : 0 }

    private enum HistoryFilter: CaseIterable {
        case all, running, succeeded, failed

        var title: LocalizedStringKey {
            switch self {
            case .all: "全部"
            case .running: "生成中"
            case .succeeded: "已完成"
            case .failed: "失败"
            }
        }

        func matches(_ status: IOSDeepReadTaskStatus) -> Bool {
            switch self {
            case .all: true
            case .running: status == .running || status == .queued
            case .succeeded: status == .succeeded
            case .failed: status == .failed || status == .unsupported
            }
        }
    }

    private var visibleHistory: [IOSDeepReadTask] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return deepReadStore.history.filter { task in
            historyFilter.matches(task.status)
                && (query.isEmpty || task.title.localizedStandardContains(query)
                    || task.resultMarkdown.localizedStandardContains(query))
        }
    }

    private struct BoardSettingsSignature: Equatable {
        let boardModelId: String?
        let hotListRefreshIntervalMinutes: Int
        let hotListWifiOnly: Bool
        let hotListEnabledSources: [String]
        let hotListFocusKeywords: [String]
        let hotListFilterMode: String
        let hotListTranslateToChinese: Bool

        init(_ setting: TodayBoardSetting) {
            boardModelId = setting.boardModelId
            hotListRefreshIntervalMinutes = Int(setting.hotListRefreshIntervalMinutes)
            hotListWifiOnly = setting.hotListWifiOnly
            hotListEnabledSources = Array(setting.hotListEnabledSources).sorted()
            hotListFocusKeywords = setting.hotListFocusKeywords
            hotListFilterMode = setting.hotListFilterMode.wireName
            hotListTranslateToChinese = setting.hotListTranslateToChinese
        }
    }

    var body: some View {
        let _ = sharedSettings.revision
        ZStack {
            AmberThemePageBackground(surface: .app)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 0) {
                        hotTopicSection
                        hotListProviderSection
                    }
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await refreshHotList(force: true)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCustomSourceSheet) {
            NavigationStack {
                ScrollView {
                    deepReadCreateSection
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(AmberTheme.background.ignoresSafeArea())
                .navigationTitle("自定义来源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showCustomSourceSheet = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showHistorySheet) {
            NavigationStack {
                ScrollView {
                    deepReadHistorySection
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(AmberTheme.background.ignoresSafeArea())
                .navigationTitle("深度阅读历史")
                .searchable(text: $historyQuery, prompt: "搜索标题与正文")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showHistorySheet = false }
                    }
                }
            }
            .presentationDetents([.large])
        }
        // 榜单条目的操作改为从底部滑入的 Liquid Glass 面板(原生 confirmationDialog 在
        // iOS 26 会渲染成居中灰卡、无下沉动效)。.sheet + 小尺寸 detent = 原生上滑动效。
        .sheet(isPresented: Binding(
            get: { topicActionTarget != nil },
            set: { if !$0 { topicActionTarget = nil } }
        )) {
            if let topic = topicActionTarget {
                let sourceURL = topic.sources
                    .compactMap(\.url)
                    .first(where: { !$0.isEmpty })
                    .flatMap { URL(string: $0) }
                // Close reading needs an article to read; discussion pages (weibo, zhihu…) have none.
                let primaryIndex = (try? IOSDeepReadSourceNormalizer.hotTopicSources(topic: topic))
                    .flatMap(DeepReadCloseReader.primaryIndex(in:))
                TopicActionSheet(
                    title: topic.title,
                    sourceURL: sourceURL,
                    canReadOriginal: primaryIndex != nil,
                    onDeepRead: {
                        topicActionTarget = nil
                        Task { await createDeepReadTask(topic: topic) }
                    },
                    onCloseRead: { originalOnly in
                        topicActionTarget = nil
                        Task { await createDeepReadTask(topic: topic, primaryIndex: primaryIndex, originalOnly: originalOnly) }
                    },
                    onOpenSource: {
                        if let sourceURL {
                            topicActionTarget = nil
                            openURL(sourceURL)
                        }
                    },
                    onRegenerate: {
                        topicActionTarget = nil
                        Task { await createDeepReadTask(topic: topic) }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(30)
            }
        }
        .fileImporter(
            isPresented: $isImportingDeepReadFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleDeepReadFileImport(result)
        }
        .onChange(of: sharedSettings.todayBoard.deepReadTemplateId, initial: true) { _, templateId in
            selectedTemplateId = IOSDeepReadTemplate.normalizedTemplateId(templateId)
        }
        .task(id: BoardSettingsSignature(sharedSettings.todayBoard)) {
            await synchronizeBoardSettings()
        }
    }

    private var header: some View {
        // Title centered on the full width via overlay so the trailing buttons
        // (history + settings) don't offset it; subtitle removed per design.
        HStack {
            AmberGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回", size: 44, symbolSize: 20) {
                dismiss()
            }

            Spacer()

            HStack(spacing: 8) {
                AmberGlassCircleButton(systemImage: "clock.arrow.circlepath", accessibilityLabel: "深度阅读历史", size: 44, symbolSize: 17) {
                    showHistorySheet = true
                }
                AmberGlassCircleButton(systemImage: "gearshape", accessibilityLabel: "深度阅读设置", size: 44, symbolSize: 17) {
                    router.navigate(to: .boardSettings)
                }
            }
        }
        .overlay {
            Text("深度阅读")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AmberTheme.foreground)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var hotTopicSection: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                AmberSectionLabel(text: "综合热榜")
                Button {
                    Task { await refreshHotList(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmberTheme.muted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .disabled(hotListStore.isRefreshing)
                .opacity(hotListStore.isRefreshing ? 0.45 : 1)
                .accessibilityLabel(hotListStore.isRefreshing ? "刷新中" : "刷新热榜")
                .padding(.trailing, 16)
                .padding(.top, 10)
            }
            AmberFormGroup {
                if !hotListStore.dashboard.hasEnabledSources {
                    hotListEmptyText("没有启用任何 iOS 支持的热榜来源。请到设置里选择 Hacker News、arXiv AI、InfoQ AI、36Kr、HF Papers 或 GitHub AI。")
                } else if hotListStore.dashboard.topics.isEmpty {
                    if hotListStore.isRefreshing {
                        hotListEmptyText("正在刷新综合热榜…")
                    } else {
                        hotListEmptyText("暂无可显示的综合热点。下拉或点标题旁刷新图标。")
                    }
                } else {
                    ForEach(Array(hotListStore.dashboard.topics.prefix(20).enumerated()), id: \.element.id) { index, topic in
                        Button {
                            topicActionTarget = topic
                        } label: {
                            IOSHotTopicRow(topic: topic, isBusy: isCreatingDeepRead)
                        }
                        .buttonStyle(.plain)
                        if index < min(hotListStore.dashboard.topics.count, 20) - 1 {
                            BoardCapabilityDivider()
                        }
                    }
                }
            }
            if let hotListMessage {
                Text(verbatim: hotListMessage)
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let message = deepReadMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(deepReadMessageIsError ? AmberTheme.accentAmber : AmberTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
    }

    private var hotListProviderSection: some View {
        VStack(spacing: 0) {
            ForEach(hotListStore.dashboard.providers) { provider in
                AmberSectionLabel(verbatim: provider.providerName)
                    .padding(.top, 10)
                AmberFormGroup {
                    if provider.items.isEmpty {
                        if let error = provider.error {
                            hotListEmptyText(verbatim: error)
                        } else {
                            hotListEmptyText("这个来源暂时没有可显示内容。")
                        }
                    } else {
                        ForEach(Array(provider.items.prefix(8).enumerated()), id: \.offset) { index, item in
                            Button {
                                topicActionTarget = IOSHotListDashboardStore.topic(from: provider, item: item)
                            } label: {
                                IOSHotProviderItemRow(provider: provider, item: item)
                            }
                            .buttonStyle(.plain)
                            if index < min(provider.items.count, 8) - 1 {
                                BoardCapabilityDivider()
                            }
                        }
                    }
                }
                if provider.stale || (provider.error ?? "").isEmpty == false {
                    if provider.stale {
                        BoardCapabilityNote("这个来源刷新失败，当前显示的是上次缓存。")
                    } else {
                        BoardCapabilityNote(verbatim: IOSAppLocalization.formatted(
                            "刷新失败：%@",
                            defaultValue: "刷新失败：%@",
                            arguments: [provider.error ?? IOSAppLocalization.string("未知错误", defaultValue: "未知错误")]
                        ))
                    }
                }
            }
        }
    }

    private func hotListEmptyText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    private func hotListEmptyText(verbatim text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(AmberTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }


    private var deepReadCreateSection: some View {
        VStack(spacing: 0) {
            AmberSectionLabel(text: "创建深度阅读")
            AmberFormGroup {
                VStack(alignment: .leading, spacing: 12) {
                    deepReadTextField(title: "标题", text: $deepReadTitle, placeholder: "要阅读的主题")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("手动文本")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AmberTheme.foreground)
                        TextEditor(text: $manualText)
                            .font(.footnote)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 92)
                            .padding(8)
                            .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    deepReadTextField(title: "搜索", text: $searchQuery, placeholder: "可选：搜索一个主题并纳入来源")

                    deepReadTextField(title: "链接", text: $links, placeholder: "可选：网页链接，多个用空格分隔")
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)

                    VStack(alignment: .leading, spacing: 6) {
                        Picker("阅读方式", selection: $readingMode) {
                            Text("多源综述").tag(ReadingMode.synthesis)
                            Text("精读").tag(ReadingMode.closeReading)
                            Text("只读原文").tag(ReadingMode.originalOnly)
                        }
                        .pickerStyle(.segmented)
                        Text(readingModeNote)
                            .font(.caption)
                            .foregroundStyle(AmberTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Generation templates shape topic syntheses; a close reading keeps the original's structure.
                    if readingMode == .synthesis {
                        Picker("生成模板", selection: $selectedTemplateId) {
                            ForEach(DeepReadSynthesisTemplate.options, id: \.id) { option in
                                Label(IOSAppLocalization.string(option.name, defaultValue: option.name), systemImage: option.symbol)
                                    .tag(option.id)
                            }
                            ForEach(IOSDeepReadTemplateStore.shared.templates) { template in
                                Text(verbatim: template.name).tag(template.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AmberTheme.foreground)
                    }

                    AmberGlassGroup(spacing: 16) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await createDeepReadTask(includeConversation: true) }
                            } label: {
                                Label(isCreatingDeepRead ? "生成中" : "生成", systemImage: isCreatingDeepRead ? "clock.arrow.circlepath" : "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isCreatingDeepRead)

                            Button {
                                isImportingDeepReadFile = true
                            } label: {
                                Image(systemName: "doc.badge.plus")
                                    .frame(width: 42)
                            }
                            .buttonStyle(.glass)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("从文件创建深度阅读")

                            Button {
                                Task { await createFromWebMount() }
                            } label: {
                                Image(systemName: "globe")
                                    .frame(width: 42)
                            }
                            .buttonStyle(.glass)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("从当前 WebMount 页面创建深度阅读")
                        }
                    }

                    Button {
                        Task { await createDeepReadTask(includeConversation: false) }
                    } label: {
                        Label("只使用手动文本/搜索", systemImage: "text.badge.checkmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .disabled(isCreatingDeepRead)

                    if let deepReadMessage {
                        Text(deepReadMessage)
                            .font(.footnote)
                            .foregroundStyle(deepReadMessageIsError ? AmberTheme.accentAmber : AmberTheme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            BoardCapabilityNote("文件只读取你前台选择的 txt、md、json、csv、pdf、docx 文本预览；WebMount 只读取当前已加载页面正文。")
        }
    }

    private var readingModeNote: String {
        switch readingMode {
        case .synthesis: "自动从多个角度搜索资料，再结合你提供的来源生成文章。"
        case .closeReading: "以唯一的来源（文本、链接、文件或网页）为正文，配导读、模块和段落批注，并对照其他报道。"
        case .originalOnly: "只抓取并排版原文，不调用模型；之后可以在文章页生成精读。"
        }
    }

    private func deepReadTextField(title: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .fixedSize(horizontal: true, vertical: false)
            TextField(placeholder, text: text)
                .font(.footnote)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deepReadHistorySection: some View {
        let tasks = visibleHistory
        let filtering = historyFilter != .all || !historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    BoardSettingsChip(title: filter.title, selected: historyFilter == filter) {
                        historyFilter = filter
                    }
                    .accessibilityAddTraits(historyFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .sensoryFeedback(.selection, trigger: historyFilter)
            AmberSectionLabel(text: "历史")
            AmberFormGroup {
                if let message = deepReadStore.loadError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AmberTheme.accentAmber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else if tasks.isEmpty {
                    Text(filtering ? "没有匹配的深度阅读。尝试其他关键词或状态。" : "还没有深度阅读任务。创建后会保存到本机历史。")
                        .font(.caption)
                        .foregroundStyle(AmberTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    // Searching and filtering reach the whole library; the unfiltered list stays at the latest 20.
                    let shown = filtering ? tasks : Array(tasks.prefix(20))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, task in
                        Button {
                            // 先收起历史 sheet，再在主导航栈上跳转到文章。两者是独立状态，
                            // 文章已 push 到 sheet 之下，收起 sheet 即直接露出文章，避免
                            // 「点了没反应、反复点」的错觉。
                            showHistorySheet = false
                            router.navigate(to: .deepReadTask(id: task.id))
                        } label: {
                            IOSDeepReadHistoryRow(task: task)
                        }
                        .buttonStyle(.plain)
                        if index < shown.count - 1 {
                            BoardCapabilityDivider()
                        }
                    }
                }
            }
        }
    }

    private func createDeepReadTask(includeConversation: Bool) async {
        guard !isCreatingDeepRead else { return }
        isCreatingDeepRead = true
        deepReadMessage = nil
        deepReadMessageIsError = false
        defer { isCreatingDeepRead = false }

        do {
            var sources: [IOSDeepReadSource] = []
            if !manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(try IOSDeepReadSourceNormalizer.manualText(title: deepReadTitle, text: manualText))
            }
            for link in links.split(whereSeparator: \.isWhitespace) {
                let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    deepReadMessage = "网页链接需要完整的 http 或 https 地址：\(value)"
                    deepReadMessageIsError = true
                    return
                }
                sources.append(IOSDeepReadSource(kind: .searchResult, title: url.host ?? value, content: value, url: value))
            }
            // A close reading reads one given source; the current conversation only stands in when there is none.
            if includeConversation, readingMode == .synthesis || sources.isEmpty,
               let source = try? conversationStore.currentConversationDeepReadSource() {
                sources.append(source)
            }
            if readingMode != .synthesis {
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sources.count == 1 else {
                    deepReadMessage = "精读和只读原文需要恰好一个来源：一段文本、一个链接、一个文件或当前网页。"
                    deepReadMessageIsError = true
                    return
                }
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let execution = try await IOSSearchExecutor.searchResults(
                        toolInput: searchToolInput(query: searchQuery, maxResults: 5),
                        settings: sharedSettings.snapshot
                    )
                    sources.append(contentsOf: try IOSDeepReadSourceNormalizer.searchSources(
                        query: execution.request.query,
                        results: execution.results
                    ))
                } catch {
                    // Record the failed search as a distinct, machine-readable
                    // source-failure state (scrape_status=failed) instead of a
                    // plain manual source — so it is not silently fed to the model
                    // as factual content (the generator excludes it).
                    sources.append(try IOSDeepReadSourceNormalizer.searchFailureSource(
                        query: searchQuery,
                        error: IOSDeepReadUserFacingText.fromError(error)
                    ))
                }
            }
            try createAndGenerateTask(title: deepReadTitle, sources: sources, templateId: selectedTemplateId,
                                      primaryIndex: closeReadingIndex, originalOnly: readingMode == .originalOnly)
            manualText = ""
            searchQuery = ""
            links = ""
            showCustomSourceSheet = false
        } catch {
            deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
            deepReadMessageIsError = true
        }
    }

    private func createDeepReadTask(topic: IOSHotTopic, primaryIndex: Int? = nil, originalOnly: Bool = false) async {
        guard !isCreatingDeepRead else { return }
        isCreatingDeepRead = true
        deepReadMessage = nil
        deepReadMessageIsError = false
        defer { isCreatingDeepRead = false }

        do {
            // 先用基础来源建任务并「立刻」跳转到生成中页面,消除点击后数秒的等待;
            // 网页抓取增强和多源搜索由共享 DeepRead launcher 在生成任务里处理。
            let baseSources = try IOSDeepReadSourceNormalizer.hotTopicSources(topic: topic)
            try createAndGenerateTask(
                title: topic.title,
                sources: baseSources,
                templateId: sharedSettings.todayBoard.deepReadTemplateId,
                primaryIndex: primaryIndex,
                originalOnly: originalOnly
            )
        } catch {
            deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
            deepReadMessageIsError = true
        }
    }

    private func createAndGenerateTask(
        title: String,
        sources: [IOSDeepReadSource],
        templateId: String,
        primaryIndex: Int? = nil,
        originalOnly: Bool = false
    ) throws {
        try IOSDeepReadLauncher.createAndGenerate(
            title: title,
            sources: sources,
            templateId: templateId,
            primaryIndex: primaryIndex,
            originalOnly: originalOnly,
            sharedSettings: sharedSettings,
            navigate: { router.navigate(to: .deepReadTask(id: $0)) },
            onStatus: { message, isError in
                deepReadMessage = isError ? IOSDeepReadUserFacingText.sanitize(message) : message
                deepReadMessageIsError = isError
                if !isError, message.contains("已生成") {
                    deepReadTitle = ""
                }
            }
        )
    }

    private func refreshHotList(force: Bool) async {
        let board = sharedSettings.todayBoard
        hotListMessage = nil
        if board.hotListWifiOnly {
            let wifiSatisfied = await IOSHotListWiFiGate.isSatisfied()
            guard !Task.isCancelled else { return }
            guard wifiSatisfied else {
                hotListStore.applyCached(setting: board)
                hotListMessage = IOSAppLocalization.string(
                    "仅 Wi‑Fi 刷新：当前网络不是 Wi‑Fi，已保留缓存。",
                    defaultValue: "仅 Wi‑Fi 刷新：当前网络不是 Wi‑Fi，已保留缓存。"
                )
                return
            }
        }
        // Translation is opt-in. When enabled, every refresh re-checks for
        // untranslated titles and fills them in if a provider/model is available.
        var translate: IOSHotListTitleTranslate? = nil
        if board.hotListTranslateToChinese,
           let resolved = sharedSettings.resolveBoardDeepReadModel(boardModelId: board.boardModelId) {
            translate = { titles in
                await IOSHotListTitleTranslator.translate(
                    titles: titles,
                    providerSetting: resolved.provider,
                    modelId: resolved.model.modelId
                )
            }
        }
        NSLog("[AmberTranslate] refresh force=\(force) enabled=\(board.hotListTranslateToChinese) modelResolved=\(translate != nil) modelId=\(sharedSettings.resolveBoardDeepReadModel(boardModelId: board.boardModelId)?.model.modelId ?? "nil")")
        await hotListStore.refresh(setting: board, force: force, translate: translate)
    }

    private func synchronizeBoardSettings() async {
        let board = sharedSettings.todayBoard
        let signature = BoardSettingsSignature(board)
        guard appliedBoardSettings != signature else { return }
        if appliedBoardSettings == nil {
            consumeWebMountHandoffIfNeeded()
        }

        // A prior foreground refresh can still be finishing after this view
        // returns from settings. Wait for it instead of letting the store's
        // in-flight guard swallow the settings update.
        while hotListStore.isRefreshing {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled else { return }
        await refreshHotList(force: false)
        if !Task.isCancelled {
            appliedBoardSettings = signature
        }
    }

    private func createFromWebMount() async {
        guard !isCreatingDeepRead else { return }
        isCreatingDeepRead = true
        defer { isCreatingDeepRead = false }
        let result = await IOSDeepReadWebMountAdapter.currentPageSource()
        switch result {
        case .success(let source):
            do {
                try createAndGenerateTask(
                    title: source.title,
                    sources: [source],
                    templateId: sharedSettings.todayBoard.deepReadTemplateId,
                    primaryIndex: closeReadingIndex,
                    originalOnly: readingMode == .originalOnly
                )
            } catch {
                deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
                deepReadMessageIsError = true
            }
        case .failure(let error):
            deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
            deepReadMessageIsError = true
        }
    }

    private func handleDeepReadFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                deepReadMessage = IOSAppLocalization.string("没有选择文件。", defaultValue: "没有选择文件。")
                deepReadMessageIsError = true
                return
            }
            documentStore.registerPickedFile(url)
            Task {
                isCreatingDeepRead = true
                defer { isCreatingDeepRead = false }
                let read = await documentStore.readSelectedDocumentForDeepRead()
                switch read {
                case .success(let source):
                    do {
                        try createAndGenerateTask(
                            title: source.title,
                            sources: [source],
                            templateId: sharedSettings.todayBoard.deepReadTemplateId,
                            primaryIndex: closeReadingIndex,
                            originalOnly: readingMode == .originalOnly
                        )
                    } catch {
                        deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
                        deepReadMessageIsError = true
                    }
                case .failure(let error):
                    deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
                    deepReadMessageIsError = true
                }
            }
        case .failure(let error):
            deepReadMessage = IOSAppLocalization.formatted(
                "文件选择失败：%@",
                defaultValue: "文件选择失败：%@",
                arguments: [IOSDeepReadUserFacingText.fromError(error)]
            )
            deepReadMessageIsError = true
        }
    }

    private func searchToolInput(query: String, maxResults: Int) -> String {
        let object: [String: Any] = ["query": query, "max_results": maxResults]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return query
        }
        return string
    }

    private func consumeWebMountHandoffIfNeeded() {
        guard let handoff = IOSWebMountContentHandoffStore.shared.consumeDeepReadHandoff() else { return }
        let repository = IOSBoardSignalRepository.shared
        let outcome = repository.ingest(handoff.boardSignal)
        collectionSnapshot = IOSBoardCollectionSnapshot(
            statuses: [],
            recentSignals: repository.recentSignals(limit: 10),
            pendingCount: repository.countUnprocessedSignals(),
            lastRunAt: nil,
            lastRunError: nil
        )
        let outcomeText: String
        switch outcome {
        case .saved:
            outcomeText = "已把 \(handoff.siteName) 的网页内容转入深度阅读线索。"
        case .duplicateSourceRef, .duplicateContentHash:
            outcomeText = "\(handoff.siteName) 的网页内容已在深度阅读线索中。"
        }
        generationState = BoardGenerationState(
            isRunning: false,
            message: "\(outcomeText) 点击“生成线索摘要”开始整理。",
            signals: [],
            output: nil,
            isError: false
        )
    }

}

private struct BoardGenerationState {
    var isRunning: Bool
    var message: String?
    var signals: [BoardSignalPreviewItem]
    var output: String?
    var isError: Bool

    static let idle = BoardGenerationState(
        isRunning: false,
        message: "尚未生成。点击按钮后会整理本机可用线索。",
        signals: [],
        output: nil,
        isError: false
    )

    static func running(message: String, signals: [BoardSignalPreviewItem] = []) -> BoardGenerationState {
        BoardGenerationState(isRunning: true, message: message, signals: signals, output: nil, isError: false)
    }

    static func finished(message: String, signals: [BoardSignalPreviewItem], output: String) -> BoardGenerationState {
        BoardGenerationState(isRunning: false, message: message, signals: signals, output: output, isError: false)
    }

    static func failed(_ message: String) -> BoardGenerationState {
        BoardGenerationState(isRunning: false, message: message, signals: [], output: nil, isError: true)
    }
}

private struct BoardSignalPreviewItem: Identifiable {
    let id = UUID()
    let sourceType: String
    let sourceRef: String
    let title: String

    static func from(_ signals: [BoardSignal]) -> [BoardSignalPreviewItem] {
        signals.map {
            BoardSignalPreviewItem(
                sourceType: $0.sourceType,
                sourceRef: $0.sourceRef,
                title: $0.title
            )
        }
    }
}

#Preview {
    NavigationStack {
        BoardView(settingsStore: SettingsStore(), sharedSettings: IOSSharedSettingsStore())
            .environment(RouterPath())
            .environment(IOSConversationStore())
            .environment(DocumentAccessStore())
    }
}
