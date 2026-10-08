import Foundation
import Observation
import UIKit
@preconcurrency import Shared

enum DeepReadRuntimeError: LocalizedError {
    case missingTask
    case alreadyRunning
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .missingTask: "深度阅读记录不存在。"
        case .alreadyRunning: "这篇深度阅读正在生成。"
        case .emptyTitle: "请输入阅读主题或添加来源。"
        }
    }
}

/// App-level owner: leaving a page never cancels generation. The background
/// allowance is best effort; expiration saves a terminal state before releasing it.
@Observable
@MainActor
final class DeepReadRuntime {
    typealias BackgroundTaskStarter = @MainActor (_ name: String, _ expiration: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    typealias SourceSearch = @MainActor (_ title: String, _ settings: Settings?) async -> [IOSDeepReadSource]
    typealias SourceEnrichment = @MainActor (_ sources: [IOSDeepReadSource], _ settings: Settings?, _ progress: @escaping (Int, Int) -> Void) async -> [IOSDeepReadSource]
    typealias PrimaryFetch = @MainActor (_ url: String, _ settings: Settings?) async throws -> DeepReadCloseReader.Page
    private struct PriorCompletion {
        let markdown: String
        let structuredJSON: String?
        let missingSections: [String]?
    }

    private struct Run {
        let id: UUID
        let prior: PriorCompletion?
        var operation: Task<Void, Never>?
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
    }

    let store: IOSDeepReadStore
    let settings: DeepReadSettingsStore
    private(set) var activeTaskIds: Set<String> = []
    private(set) var lastError: String?
    private(set) var errorsByTaskId: [String: String] = [:]
    @ObservationIgnored private var runs: [String: Run] = [:]
    @ObservationIgnored private let provider: any IOSAgentTextProvider
    @ObservationIgnored private let searchSources: SourceSearch
    @ObservationIgnored private let enrichSources: SourceEnrichment
    @ObservationIgnored private let fetchPrimary: PrimaryFetch
    @ObservationIgnored private let searchReports: SourceSearch
    @ObservationIgnored private let beginBackgroundTask: BackgroundTaskStarter
    @ObservationIgnored private let endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void

    init(
        settings: DeepReadSettingsStore,
        store: IOSDeepReadStore = .shared,
        provider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        searchSources: @escaping SourceSearch = { title, settings in
            await DeepReadSourceCollector.search(title: title, settings: settings)
        },
        enrichSources: @escaping SourceEnrichment = { sources, settings, progress in
            await DeepReadSourceCollector.enrich(sources, settings: settings, onSourceProgress: progress)
        },
        fetchPrimary: @escaping PrimaryFetch = { url, settings in
            try await DeepReadCloseReader.fetch(url: url, settings: settings)
        },
        searchReports: @escaping SourceSearch = { title, settings in
            await DeepReadSourceCollector.search(title: title, settings: settings, queries: [title])
        },
        beginBackgroundTask: @escaping BackgroundTaskStarter = { name, expiration in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
        },
        endBackgroundTask: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        self.settings = settings
        self.store = store
        self.provider = provider
        self.searchSources = searchSources
        self.enrichSources = enrichSources
        self.fetchPrimary = fetchPrimary
        self.searchReports = searchReports
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
    }

    /// `primaryIndex` names the source read in full as the article body; the other sources
    /// become reports compared against it. Nil keeps the topic synthesis.
    @discardableResult
    func create(title: String, sources: [IOSDeepReadSource], templateId: String? = nil,
                primaryIndex: Int? = nil, originalOnly: Bool = false) throws -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || !sources.isEmpty else { throw DeepReadRuntimeError.emptyTitle }
        // A topic is a search seed, never an invented factual source.
        var input = sources.isEmpty
            ? [IOSDeepReadSource(kind: .hotTopic, title: cleaned, content: cleaned)] : sources
        if let primaryIndex, input.indices.contains(primaryIndex) {
            input[primaryIndex].metadata[DeepReadCloseReader.roleKey] = DeepReadCloseReader.primaryRole
            if cleaned.isEmpty { input[primaryIndex].metadata[DeepReadCloseReader.titlePendingKey] = "true" }
            if originalOnly { input[primaryIndex].metadata[DeepReadCloseReader.originalOnlyKey] = "true" }
        }
        let task = try store.createTask(title: cleaned, sources: input, templateId: templateId ?? settings.templateId)
        guard store.markRunning(id: task.id) else { throw IOSDeepReadStoreError.persistenceFailed }
        start(taskId: task.id)
        return task.id
    }

    func retry(taskId: String) throws {
        guard runs[taskId] == nil else { throw DeepReadRuntimeError.alreadyRunning }
        guard let current = store.task(id: taskId) else { throw DeepReadRuntimeError.missingTask }
        let prior = current.resultMarkdown.isEmpty ? nil : PriorCompletion(
            markdown: current.resultMarkdown,
            structuredJSON: current.structuredJSON,
            missingSections: current.missingSections
        )
        let initialOutput = current.structuredJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }
        let missing = current.missingSections ?? []
        guard store.prepareRetry(id: taskId, preservingResult: prior != nil) else {
            throw IOSDeepReadStoreError.persistenceFailed
        }
        start(taskId: taskId, prior: prior, initialOutput: initialOutput,
              targetStages: missing.isEmpty ? nil : Set(missing))
    }

    /// Turns a "只读原文" reading into a full close reading; the original stays visible meanwhile.
    func annotate(taskId: String) throws {
        guard runs[taskId] == nil else { throw DeepReadRuntimeError.alreadyRunning }
        guard var sources = store.task(id: taskId)?.sources else { throw DeepReadRuntimeError.missingTask }
        for index in sources.indices { sources[index].metadata.removeValue(forKey: DeepReadCloseReader.originalOnlyKey) }
        guard store.replaceSources(id: taskId, sources: sources) else { throw IOSDeepReadStoreError.persistenceFailed }
        try retry(taskId: taskId)
    }

    private static let missingModelMessage = "请在设置中配置服务商、选择可用的阅读模型，并点击“保存并应用”。"

    func cancel(taskId: String) {
        guard let run = runs[taskId] else { return }
        interrupt(taskId: taskId, runId: run.id, message: "生成已取消，可稍后重试。")
    }

    func error(for taskId: String) -> String? { errorsByTaskId[taskId] }

    /// Cold start marks orphaned tasks interrupted. It does not resume provider calls.
    func recoverInterruptedRuns() {
        // Exclude every live owner even when its last disk update is old.
        for task in store.tasks where !activeTaskIds.contains(task.id)
            && (task.status == .running || task.status == .queued) {
            if !task.resultMarkdown.isEmpty {
                recordError("上次生成被中断，已保留已有文章，可重新生成。", taskId: task.id)
                if !store.complete(id: task.id, markdown: task.resultMarkdown,
                                   structuredJSON: task.structuredJSON, missingSections: task.missingSections) {
                    reportPersistenceFailure(taskId: task.id)
                }
            } else if !store.fail(id: task.id, message: "上次深度阅读生成被中断，可重试。") {
                reportPersistenceFailure(taskId: task.id)
            }
        }
    }

    private func start(taskId: String, prior: PriorCompletion? = nil,
                       initialOutput: IOSDeepReadOutput? = nil, targetStages: Set<String>? = nil) {
        guard runs[taskId] == nil else { return }
        if lastError != nil { lastError = nil }
        if errorsByTaskId[taskId] != nil { errorsByTaskId.removeValue(forKey: taskId) }
        let runId = UUID()
        runs[taskId] = Run(id: runId, prior: prior)
        activeTaskIds.insert(taskId)
        let backgroundID = beginBackgroundTask("DeepRead:\(taskId)") { [weak self] in
            Task { @MainActor in
                self?.interrupt(taskId: taskId, runId: runId, message: "后台生成被系统中断，可稍后重试。")
            }
        }
        runs[taskId]?.backgroundID = backgroundID
        let operation = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(taskId: taskId, runId: runId) else { return }
            await self.generate(taskId: taskId, runId: runId,
                                initialOutput: initialOutput, targetStages: targetStages)
            self.finish(taskId: taskId, runId: runId)
        }
        runs[taskId]?.operation = operation
    }

    private func generate(taskId: String, runId: UUID,
                          initialOutput: IOSDeepReadOutput?, targetStages: Set<String>?) async {
        guard var task = store.task(id: taskId) else { return }
        let primary = task.sources.firstIndex(where: DeepReadCloseReader.isPrimary)
        // Reading only the original never calls a model, so it needs none configured.
        let originalOnly = primary.map { task.sources[$0].metadata[DeepReadCloseReader.originalOnlyKey] == "true" } ?? false
        let resolved = settings.resolvedModel
        guard resolved != nil || originalOnly else {
            fail(taskId: taskId, message: Self.missingModelMessage)
            return
        }
        guard store.markRunning(id: taskId) else { reportPersistenceFailure(taskId: taskId); return }
        if let primary {
            await generateCloseReading(task: task, primaryIndex: primary, resolved: resolved, runId: runId)
            return
        }
        guard let resolved else { return }
        // Capture the complete settings once so editing settings cannot mix credentials
        // between the different search angles in an active run.
        let searchSettings = settings.searchSettings
        setProgress("正在搜索补充来源", taskId: taskId)
        let searched = await searchSources(task.title, searchSettings)
        guard isCurrent(taskId: taskId, runId: runId) else { return }
        // Search warnings belong to this collection attempt; user inputs and
        // webpage scrape failures remain durable across retries.
        let retained = task.sources.filter {
            !($0.metadata["search_query"] != nil && $0.metadata["scrape_status"] == "failed")
        }
        let merged = DeepReadSourceCollector.dedupe(retained + searched)
        setProgress("正在抓取网页正文", taskId: taskId)
        let enriched = await enrichSources(merged, searchSettings, { index, total in
            guard self.isCurrent(taskId: taskId, runId: runId) else { return }
            self.setProgress("正在抓取网页正文 \(index)/\(total)", taskId: taskId)
        })
        guard isCurrent(taskId: taskId, runId: runId) else { return }
        guard store.replaceSources(id: taskId, sources: enriched) else {
            reportPersistenceFailure(taskId: taskId); return
        }
        task.sources = enriched
        guard enriched.contains(where: \.hasUsableGenerationContent) else {
            fail(taskId: taskId, message: "没有找到可用来源。请添加文本、文件或网页，或配置搜索服务后重试。")
            return
        }
        if let template = DeepReadSynthesisTemplate(rawValue: task.templateId) {
            let numbered = DeepReadTemplateWriter.numbered(task.sources)
            var chosen: DeepReadSynthesisTemplate? = template
            // Completing a magazine article that auto mode already chose must not switch templates.
            if template == .auto, initialOutput?.hasStructuredBody == true {
                chosen = nil
            } else if template == .auto {
                setProgress("正在生成写作框架", taskId: taskId)
                let (pick, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                    prompt: DeepReadTemplateWriter.pickPrompt(topic: task.title, numbered: numbered),
                    providerSetting: resolved.provider, model: resolved.model, provider: provider, timeoutSeconds: 60)
                guard isCurrent(taskId: taskId, runId: runId) else { return }
                // Nil (the classic magazine, or an unreadable pick) continues with the shared pipeline below.
                chosen = DeepReadTemplateWriter.parsePick(pick)
            }
            if let chosen {
                setProgress("正在生成\(chosen.name)", taskId: taskId)
                let (text, error) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                    prompt: DeepReadTemplateWriter.prompt(chosen, topic: task.title, numbered: numbered),
                    providerSetting: resolved.provider, model: resolved.model, provider: provider)
                guard isCurrent(taskId: taskId, runId: runId), store.task(id: taskId)?.status == .running else { return }
                guard let article = DeepReadTemplateWriter.parse(text, template: chosen, topic: task.title, numbered: numbered) else {
                    fail(taskId: taskId, message: "深度阅读生成失败：\(IOSDeepReadUserFacingText.sanitize(error ?? "模型没有按「\(chosen.name)」模板返回内容。"))")
                    return
                }
                if !store.complete(id: taskId, markdown: DeepReadTemplateWriter.markdown(article), structuredJSON: article.encoded()) {
                    reportPersistenceFailure(taskId: taskId)
                }
                return
            }
        }
        setProgress("正在生成深度阅读", taskId: taskId)
        let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
            task: task, providerSetting: resolved.provider, model: resolved.model, provider: provider,
            onStageProgress: { label, _, _ in
                guard self.isCurrent(taskId: taskId, runId: runId) else { return }
                self.setProgress("正在生成\(label)", taskId: taskId)
            }, initialOutput: initialOutput, targetStages: targetStages
        )
        guard isCurrent(taskId: taskId, runId: runId), store.task(id: taskId)?.status == .running else { return }
        switch IOSDeepReadDraftGenerator.outcome(for: result, offlineFallback: IOSDeepReadDraftGenerator.generate(task: task)) {
        case .failed(let reason):
            fail(taskId: taskId, message: "深度阅读生成失败：\(IOSDeepReadUserFacingText.sanitize(reason))")
        case .completed(let markdown, let json):
            if !store.complete(id: taskId, markdown: markdown, structuredJSON: json,
                               missingSections: result.missingSections.isEmpty ? nil : result.missingSections) {
                reportPersistenceFailure(taskId: taskId)
            }
        }
    }

    /// Close reading: the primary text is read in full, numbered and annotated, then compared
    /// with other reports on the same story (the topic's other sources plus a title search).
    private func generateCloseReading(task: IOSDeepReadTask, primaryIndex: Int,
                                      resolved: (model: Model, provider: ProviderSetting)?, runId: UUID) async {
        let taskId = task.id
        let searchSettings = settings.searchSettings
        var primary = task.sources[primaryIndex]
        var page = DeepReadCloseReader.Page(title: primary.title, text: primary.content, heroImageURL: primary.metadata["hero_image_url"])
        if let url = primary.url, primary.metadata["scrape_status"] != "ok" {
            setProgress("正在抓取原文正文", taskId: taskId)
            do {
                page = try await fetchPrimary(url, searchSettings)
            } catch {
                guard isCurrent(taskId: taskId, runId: runId) else { return }
                fail(taskId: taskId, message: "原文读取失败：\(IOSDeepReadUserFacingText.fromError(error))")
                return
            }
            guard isCurrent(taskId: taskId, runId: runId) else { return }
            primary.content = page.text
            if !page.title.isEmpty { primary.title = page.title }
            primary.metadata["scrape_status"] = "ok"
            if let hero = page.heroImageURL { primary.metadata["hero_image_url"] = hero }
        }
        // A page without a <title> keeps the source's own title (the hot-list headline or the link's host).
        if page.title.isEmpty { page.title = primary.title }
        if primary.metadata.removeValue(forKey: DeepReadCloseReader.titlePendingKey) != nil, !page.title.isEmpty {
            _ = store.updateTitle(id: taskId, title: page.title)
        }
        let paragraphs = DeepReadCloseReader.segment(primary.content)
        guard !paragraphs.isEmpty else {
            fail(taskId: taskId, message: "原文没有可读的正文。")
            return
        }
        let site = DeepReadCloseReader.siteName(primary.url) ?? primary.title
        if primary.metadata[DeepReadCloseReader.originalOnlyKey] == "true" {
            var sources = task.sources
            sources[primaryIndex] = primary
            let reading = DeepReadCloseReader.unannotated(page: page, url: primary.url, site: site, paragraphs: paragraphs)
            if !store.replaceSources(id: taskId, sources: sources)
                || !store.complete(id: taskId, markdown: DeepReadCloseReader.markdown(reading), structuredJSON: reading.encoded()) {
                reportPersistenceFailure(taskId: taskId)
            }
            return
        }
        guard let resolved else {
            fail(taskId: taskId, message: Self.missingModelMessage)
            return
        }

        // Other reports: the topic's remaining sources plus a search on the article's title.
        setProgress("正在抓取其他报道", taskId: taskId)
        let searchTitle = store.task(id: taskId)?.title ?? task.title
        let searched = await searchReports(searchTitle, searchSettings)
        guard isCurrent(taskId: taskId, runId: runId) else { return }
        let primaryURL = primary.url
        let inputs = task.sources.filter { !DeepReadCloseReader.isPrimary($0) }
        // The title search usually finds the original itself, often under another URL form.
        let candidates = Array(DeepReadSourceCollector.dedupe(inputs + searched)
            .filter { $0.url != nil && !DeepReadCloseReader.sameArticle($0.url, primaryURL) && $0.metadata["scrape_status"] != "failed" }
            .prefix(DeepReadCloseReader.maxOtherReports))
        let enriched = await enrichSources(candidates, searchSettings, { index, total in
            guard self.isCurrent(taskId: taskId, runId: runId) else { return }
            self.setProgress("正在抓取其他报道 \(index)/\(total)", taskId: taskId)
        })
        guard isCurrent(taskId: taskId, runId: runId) else { return }
        // The topic's other inputs that were not compared this time stay with the task for later retries;
        // search results that could not be read are dropped so a retry can find and scrape them again.
        let compared = Set(candidates.map(\.id))
        let kept = [primary] + (enriched + inputs.filter { !compared.contains($0.id) })
            .filter { !($0.metadata["search_query"] != nil && $0.metadata["scrape_status"] == "failed") }
        guard store.replaceSources(id: taskId, sources: kept) else { reportPersistenceFailure(taskId: taskId); return }

        setProgress("正在生成导读与批注", taskId: taskId)
        let (guideText, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
            prompt: DeepReadCloseReader.prompt(title: page.title, site: site, paragraphs: paragraphs),
            providerSetting: resolved.provider, model: resolved.model, provider: provider)
        guard isCurrent(taskId: taskId, runId: runId) else { return }
        // A failed guide still leaves a readable original, marked partial so a retry can fill it in.
        let annotated = DeepReadCloseReader.parse(guideText, page: page, url: primary.url, site: site, paragraphs: paragraphs)
        var reading = annotated ?? DeepReadCloseReader.unannotated(page: page, url: primary.url, site: site, paragraphs: paragraphs)
        var missing = annotated == nil ? [DeepReadCloseReader.missingSection] : []

        let others = enriched.filter(\.hasUsableGenerationContent).enumerated()
            .map { DeepReadCloseReader.OtherInput(id: $0.offset + 1, source: $0.element) }
        // Comparison notes hang on a guided reading; without a guide the page only shows the original.
        if annotated != nil, !others.isEmpty {
            setProgress("正在生成别家说法", taskId: taskId)
            let (compareText, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                prompt: DeepReadCloseReader.comparePrompt(reading: reading, others: others),
                providerSetting: resolved.provider, model: resolved.model, provider: provider)
            guard isCurrent(taskId: taskId, runId: runId) else { return }
            if let compared = DeepReadCloseReader.mergeComparison(compareText, into: reading, others: others) {
                reading = compared
            } else {
                missing.append(DeepReadCloseReader.compareMissingSection)
            }
        }
        guard store.task(id: taskId)?.status == .running else { return }
        if !store.complete(id: taskId, markdown: DeepReadCloseReader.markdown(reading), structuredJSON: reading.encoded(),
                           missingSections: missing.isEmpty ? nil : missing) {
            reportPersistenceFailure(taskId: taskId)
        }
    }

    private func setProgress(_ label: String, taskId: String) {
        if store.progressLabel(for: taskId) != label { store.setProgressLabel(id: taskId, label) }
    }

    private func isCurrent(taskId: String, runId: UUID) -> Bool {
        !Task.isCancelled && runs[taskId]?.id == runId
    }

    private func fail(taskId: String, message: String) {
        let saved: Bool
        if let prior = runs[taskId]?.prior {
            saved = store.complete(id: taskId, markdown: prior.markdown,
                                   structuredJSON: prior.structuredJSON, missingSections: prior.missingSections)
        } else {
            saved = store.fail(id: taskId, message: message)
        }
        recordError(saved ? message : store.persistenceError(for: taskId)
            ?? IOSDeepReadStoreError.persistenceFailed.localizedDescription, taskId: taskId)
    }

    private func reportPersistenceFailure(taskId: String) {
        recordError(store.persistenceError(for: taskId) ?? IOSDeepReadStoreError.persistenceFailed.localizedDescription, taskId: taskId)
    }

    private func recordError(_ message: String, taskId: String) {
        if lastError != message { lastError = message }
        if errorsByTaskId[taskId] != message { errorsByTaskId[taskId] = message }
    }

    private func interrupt(taskId: String, runId: UUID, message: String) {
        guard let run = runs[taskId], run.id == runId else { return }
        // Durable terminal first; cancellation then prevents late callbacks writing results.
        fail(taskId: taskId, message: message)
        run.operation?.cancel()
        finish(taskId: taskId, runId: runId)
    }

    private func finish(taskId: String, runId: UUID) {
        guard let run = runs[taskId], run.id == runId else { return }
        runs.removeValue(forKey: taskId)
        activeTaskIds.remove(taskId)
        store.clearProgressLabel(id: taskId)
        if run.backgroundID != .invalid { endBackgroundTask(run.backgroundID) }
    }
}
