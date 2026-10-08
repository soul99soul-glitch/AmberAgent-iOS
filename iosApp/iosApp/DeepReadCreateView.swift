import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import Shared

/// Snapshot of a completed (possibly partial) article, kept across a retry so
/// that a retry run which ends without success (no model, no usable sources,
/// system interruption) restores the last good draft instead of leaving the
/// task failed with empty content.
struct IOSDeepReadPriorCompletion: Sendable {
    let markdown: String
    let structuredJSON: String?
    let missingSections: [String]
}

/// Shared deep-read create+generate pipeline, used by both the hot-list tap path
/// (BoardView) and the manual create form (DeepReadCreateView). Navigates to the
/// task page immediately, then runs the pipeline in-process (KeepAlive holds
/// background execution rights — same model as chat / council / novel).
@MainActor
enum IOSDeepReadLauncher {
    typealias StatusHandler = @MainActor (String, Bool) -> Void
    typealias WorkspaceArtifactSaver = @MainActor (
        _ title: String,
        _ content: String,
        _ type: IOSWorkspaceArtifactType,
        _ sourceKind: String,
        _ sourceId: String?
    ) throws -> Void

    /// `primaryIndex` names the source read in full as the article body (close reading); the
    /// other sources become reports compared against it. Nil keeps the topic synthesis.
    static func createAndGenerate(
        title: String,
        sources: [IOSDeepReadSource],
        templateId: String,
        primaryIndex: Int? = nil,
        originalOnly: Bool = false,
        sharedSettings: IOSSharedSettingsStore,
        navigate: @escaping (String) -> Void,
        onStatus: @escaping StatusHandler
    ) throws {
        let store = IOSDeepReadStore.shared
        var sources = sources
        if let primaryIndex, sources.indices.contains(primaryIndex) {
            sources[primaryIndex].metadata[DeepReadCloseReader.roleKey] = DeepReadCloseReader.primaryRole
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources[primaryIndex].metadata[DeepReadCloseReader.titlePendingKey] = "true"
            }
            if originalOnly { sources[primaryIndex].metadata[DeepReadCloseReader.originalOnlyKey] = "true" }
        }
        let task = try store.createTask(title: title, sources: sources, templateId: templateId)
        guard store.markRunning(id: task.id) else { throw IOSDeepReadStoreError.persistenceFailed }
        navigate(task.id)

        IOSDeepReadBackgroundCoordinator.shared.start(
            taskId: task.id,
            title: title,
            sharedSettings: sharedSettings,
            onStatus: onStatus
        )
    }

    static func retry(
        taskId: String,
        sharedSettings: IOSSharedSettingsStore,
        onStatus: @escaping StatusHandler
    ) {
        let store = IOSDeepReadStore.shared
        // Single-section retry (Android runSection parity): when the task completed
        // with missing sections, only regenerate those — seeding the stored
        // structured output so the targeted stages see the rest of the article.
        guard let current = store.task(id: taskId) else {
            onStatus(IOSAppLocalization.string("深度阅读记录不存在。", defaultValue: "深度阅读记录不存在。"), true)
            return
        }
        let missing = current.missingSections ?? []
        // Keep the last good draft through retry preparation and generation;
        // a failed result save must not destroy the existing article.
        let priorCompletion: IOSDeepReadPriorCompletion?
        if !current.resultMarkdown.isEmpty {
            priorCompletion = IOSDeepReadPriorCompletion(
                markdown: current.resultMarkdown,
                structuredJSON: current.structuredJSON,
                missingSections: missing
            )
        } else {
            priorCompletion = nil
        }
        let initialOutput: IOSDeepReadOutput? = current.structuredJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(IOSDeepReadOutput.self, from: $0) }
        let targetStages: Set<String>? = missing.isEmpty ? nil : Set(missing)
        guard store.prepareRetry(id: taskId, preservingResult: priorCompletion != nil) else {
            reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
            return
        }
        let title = store.task(id: taskId)?.title ?? "深度阅读"
        IOSDeepReadBackgroundCoordinator.shared.start(
            taskId: taskId,
            title: title,
            sharedSettings: sharedSettings,
            targetStages: targetStages,
            initialOutput: initialOutput,
            priorCompletion: priorCompletion,
            onStatus: onStatus
        )
    }

    /// Turns a "只读原文" reading into a full close reading. A failed run restores the original.
    static func annotate(
        taskId: String,
        sharedSettings: IOSSharedSettingsStore,
        onStatus: @escaping StatusHandler
    ) {
        let store = IOSDeepReadStore.shared
        guard var sources = store.task(id: taskId)?.sources else {
            onStatus(IOSAppLocalization.string("深度阅读记录不存在。", defaultValue: "深度阅读记录不存在。"), true)
            return
        }
        for index in sources.indices { sources[index].metadata.removeValue(forKey: DeepReadCloseReader.originalOnlyKey) }
        guard store.replaceSources(id: taskId, sources: sources) else {
            reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
            return
        }
        retry(taskId: taskId, sharedSettings: sharedSettings, onStatus: onStatus)
    }

    typealias SourceSearch = @MainActor (_ title: String, _ settings: Settings?) async -> [IOSDeepReadSource]
    typealias SourceEnrichment = @MainActor (_ sources: [IOSDeepReadSource], _ settings: Settings?,
                                             _ progress: @escaping (Int, Int) -> Void) async -> [IOSDeepReadSource]
    typealias PrimaryFetch = @MainActor (_ url: String, _ settings: Settings?) async throws -> DeepReadCloseReader.Page

    @discardableResult
    static func runExistingTask(
        taskId: String,
        sharedSettings: IOSSharedSettingsStore,
        store: IOSDeepReadStore = .shared,
        textProvider: any IOSAgentTextProvider = OpenAIKmpProviderAdapter(),
        workspaceArtifactSaver: WorkspaceArtifactSaver = IOSDeepReadLauncher.defaultWorkspaceArtifactSaver,
        onStatus: StatusHandler? = nil,
        isCurrentRun: @escaping @MainActor () -> Bool = { !Task.isCancelled },
        targetStages: Set<String>? = nil,
        initialOutput: IOSDeepReadOutput? = nil,
        priorCompletion: IOSDeepReadPriorCompletion? = nil,
        onActivityStage: (@MainActor (_ stage: AgentActivityStage, _ detail: String?) -> Void)? = nil,
        searchSources: SourceSearch = { title, settings in
            await DeepReadSourceCollector.search(title: title, settings: settings)
        },
        enrichSources: SourceEnrichment = { sources, settings, progress in
            await DeepReadSourceCollector.enrich(sources, settings: settings, onSourceProgress: progress)
        },
        fetchPrimary: PrimaryFetch = { url, settings in
            try await DeepReadCloseReader.fetch(url: url, settings: settings)
        },
        searchReports: SourceSearch = { title, settings in
            await DeepReadSourceCollector.search(title: title, settings: settings, queries: [title])
        }
    ) async -> Bool {
        defer {
            if isCurrentRun() {
                store.clearProgressLabel(id: taskId)
            }
        }
        guard isCurrentRun() else { return false }
        guard var running = store.task(id: taskId) else { return false }
        guard running.status == .queued || running.status == .running else { return false }
        let primaryIndex = running.sources.firstIndex(where: DeepReadCloseReader.isPrimary)
        // Reading only the original never calls a model, so it needs none configured.
        let originalOnly = primaryIndex.map {
            running.sources[$0].metadata[DeepReadCloseReader.originalOnlyKey] == "true"
        } ?? false
        let resolved = sharedSettings.resolveBoardDeepReadModel(
            boardModelId: sharedSettings.todayBoard.boardModelId
        )
        guard resolved != nil || originalOnly else {
            return failRun(
                taskId: taskId,
                message: IOSAppLocalization.string(
                    "深度阅读生成失败：请在深度阅读设置中选择可用模型，并检查服务商登录状态。",
                    defaultValue: "深度阅读生成失败：请在深度阅读设置中选择可用模型，并检查服务商登录状态。"
                ),
                store: store,
                onStatus: onStatus,
                priorCompletion: priorCompletion
            )
        }

        var progressTotal: Int64 = 7
        func updateProgress(_ completed: Int64, _ subtitle: String, total: Int64? = nil) {
            guard isCurrentRun() else { return }
            if let total { progressTotal = max(1, total) }
            // Progress label is in-memory only — avoid rewriting tasks.json every tick.
            store.setProgressLabel(id: taskId, subtitle)
            BackgroundGenerationKeepAlive.shared.updateProgress(
                taskId,
                completed: completed,
                total: progressTotal,
                subtitle: subtitle
            )
        }

        func reportStage(_ stage: AgentActivityStage, _ detail: String? = nil) {
            guard isCurrentRun() else { return }
            onActivityStage?(stage, detail)
        }

        guard store.markRunning(id: taskId) else {
            return reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
        }
        updateProgress(
            0,
            IOSAppLocalization.string("准备生成", defaultValue: "准备生成")
        )

        let output: String
        var structuredJSON: String? = nil
        var missingSections: [String] = []
        if let primaryIndex {
            let outcome = await generateCloseReading(
                task: running, primaryIndex: primaryIndex, resolved: resolved,
                keepsPriorGuide: DeepReadCloseReading.decode(priorCompletion?.structuredJSON)?.hasGuide == true,
                settings: sharedSettings.snapshot, store: store, textProvider: textProvider,
                isCurrentRun: isCurrentRun, progress: { updateProgress($0, $1, total: $2) }, stage: reportStage,
                fetchPrimary: fetchPrimary, searchReports: searchReports, enrichSources: enrichSources
            )
            switch outcome {
            case .aborted:
                return false
            case .persistenceFailed:
                return reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
            case .failed(let message):
                return failRun(taskId: taskId, message: message, store: store, onStatus: onStatus,
                               priorCompletion: priorCompletion)
            case .completed(let markdown, let json, let missing):
                output = markdown
                structuredJSON = json
                missingSections = missing
            }
        } else {
            // Without a primary source a model is required (checked above).
            guard let (model, providerSetting) = resolved else { return false }
            updateProgress(
                1,
                IOSAppLocalization.string("正在搜索补充来源", defaultValue: "正在搜索补充来源")
            )
            reportStage(.searching)
            let searched = await searchSources(running.title, sharedSettings.snapshot)
            guard isCurrentRun() else { return false }

            // Search warnings belong to one collection attempt; user inputs and webpage scrape
            // failures stay durable across retries.
            let retained = running.sources.filter {
                !($0.metadata["search_query"] != nil && $0.metadata["scrape_status"] == "failed")
            }
            // The generator reads at most 10 usable sources, so only those are scraped; search
            // warnings ride along to show why an angle found nothing.
            let collected = DeepReadSourceCollector.dedupe(retained + searched)
            let isWarning = { (source: IOSDeepReadSource) in
                source.metadata["search_query"] != nil && source.metadata["scrape_status"] == "failed"
            }
            let mergedSources = Array(collected.filter { !isWarning($0) }.prefix(10)) + collected.filter(isWarning)
            let scrapeBase: Int64 = 2
            let generationBase = scrapeBase + Int64(max(mergedSources.count, 1))
            progressTotal = generationBase + 5
            updateProgress(
                2,
                IOSAppLocalization.string("正在抓取网页正文", defaultValue: "正在抓取网页正文"),
                total: progressTotal
            )
            // 灵动岛显示正在抓取的那个来源；回调在每个来源抓完后触发，所以取下一个。
            reportStage(.readingWeb, AgentActivityStepDetailPolicy.webDetail(url: mergedSources.first?.url))
            let enriched = await enrichSources(
                mergedSources,
                sharedSettings.snapshot,
                { index, total in
                    updateProgress(
                        scrapeBase + Int64(index),
                        "\(IOSAppLocalization.string("正在抓取网页正文", defaultValue: "正在抓取网页正文")) \(index)/\(total)"
                    )
                    if index < mergedSources.count {
                        reportStage(.readingWeb, AgentActivityStepDetailPolicy.webDetail(url: mergedSources[index].url))
                    }
                }
            )
            guard isCurrentRun() else { return false }

            guard store.replaceSources(id: taskId, sources: enriched) else {
                return reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
            }
            running.sources = enriched
            guard enriched.contains(where: isUsableSourceForGeneration) else {
                return failRun(
                    taskId: taskId,
                    message: IOSAppLocalization.string(
                        "深度阅读生成失败：没有找到可用来源。免费搜索受网络环境和反爬限制，结果不稳定；可在「设置 › 搜索服务」添加有免费额度的 Tavily、Serper、Exa、Brave 或智谱后重试。",
                        defaultValue: "深度阅读生成失败：没有找到可用来源。免费搜索受网络环境和反爬限制，结果不稳定；可在「设置 › 搜索服务」添加有免费额度的 Tavily、Serper、Exa、Brave 或智谱后重试。"
                    ),
                    store: store,
                    onStatus: onStatus,
                    priorCompletion: priorCompletion
                )
            }

            var templateArticle: DeepReadTemplateArticle?
            // Completing a magazine article that auto mode already chose must not switch templates.
            if let template = DeepReadSynthesisTemplate(rawValue: running.templateId),
               !(template == .auto && initialOutput?.hasStructuredBody == true) {
                let numbered = DeepReadTemplateWriter.numbered(running.sources)
                var chosen: DeepReadSynthesisTemplate? = template
                reportStage(.generating)
                if template == .auto {
                    updateProgress(generationBase, IOSAppLocalization.string("正在生成写作框架", defaultValue: "正在生成写作框架"))
                    let (pick, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                        prompt: DeepReadTemplateWriter.pickPrompt(topic: running.title, numbered: numbered),
                        providerSetting: providerSetting, model: model, provider: textProvider, timeoutSeconds: 60)
                    guard isCurrentRun() else { return false }
                    // Nil (the classic magazine, or an unreadable pick) continues with the shared pipeline below.
                    chosen = DeepReadTemplateWriter.parsePick(pick)
                }
                if let chosen {
                    updateProgress(generationBase + 1, "\(IOSAppLocalization.string("正在生成", defaultValue: "正在生成"))\(chosen.name)")
                    let (text, error) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                        prompt: DeepReadTemplateWriter.prompt(chosen, topic: running.title, numbered: numbered),
                        providerSetting: providerSetting, model: model, provider: textProvider)
                    guard isCurrentRun() else { return false }
                    guard let article = DeepReadTemplateWriter.parse(text, template: chosen, topic: running.title, numbered: numbered) else {
                        return failRun(
                            taskId: taskId,
                            message: IOSAppLocalization.formatted(
                                "深度阅读生成失败：%@",
                                defaultValue: "深度阅读生成失败：%@",
                                arguments: [IOSDeepReadUserFacingText.sanitize(error ?? "模型没有按「\(chosen.name)」模板返回内容。")]
                            ),
                            store: store,
                            onStatus: onStatus,
                            priorCompletion: priorCompletion
                        )
                    }
                    templateArticle = article
                }
            }
            if let templateArticle {
                output = DeepReadTemplateWriter.markdown(templateArticle)
                structuredJSON = templateArticle.encoded()
            } else {
                updateProgress(
                    generationBase,
                    IOSAppLocalization.string("正在生成深度阅读", defaultValue: "正在生成深度阅读")
                )
                reportStage(.generating)
                let result = await IOSDeepReadDraftGenerator.generateViaLLMResult(
                    task: running,
                    providerSetting: providerSetting,
                    model: model,
                    provider: textProvider,
                    onStageProgress: { label, index, _ in
                        updateProgress(
                            generationBase + Int64(index),
                            "\(IOSAppLocalization.string("正在生成", defaultValue: "正在生成"))\(label)"
                        )
                    },
                    initialOutput: initialOutput,
                    targetStages: targetStages
                )
                guard isCurrentRun() else { return false }
                missingSections = result.missingSections
                switch IOSDeepReadDraftGenerator.outcome(
                    for: result,
                    offlineFallback: IOSDeepReadDraftGenerator.generate(task: running)
                ) {
                case .failed(let reason):
                    return failRun(
                        taskId: taskId,
                        message: IOSAppLocalization.formatted(
                            "深度阅读生成失败：%@",
                            defaultValue: "深度阅读生成失败：%@",
                            arguments: [IOSDeepReadUserFacingText.sanitize(reason)]
                        ),
                        store: store,
                        onStatus: onStatus,
                        priorCompletion: priorCompletion
                    )
                case .completed(let markdown, let json):
                    output = markdown
                    structuredJSON = json
                }
            }
        }

        // KeepAlive expire/system-cancel may have already marked failed; don't resurrect.
        guard isCurrentRun(), store.task(id: taskId)?.status == .running else { return false }

        updateProgress(
            progressTotal,
            IOSAppLocalization.string("正在保存结果", defaultValue: "正在保存结果")
        )
        reportStage(.organizing)
        guard store.complete(
            id: taskId,
            markdown: output,
            structuredJSON: structuredJSON,
            missingSections: missingSections.isEmpty ? nil : missingSections
        ) else {
            return reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
        }
        do {
            // A close reading may have replaced a pending title with the original's.
            try workspaceArtifactSaver(store.task(id: taskId)?.title ?? running.title, output, .deepRead, "deep_read", running.id)
            if missingSections.isEmpty {
                onStatus?(
                    IOSAppLocalization.string(
                        "已生成并保存深度阅读。",
                        defaultValue: "已生成并保存深度阅读。"
                    ),
                    false
                )
            } else {
                onStatus?(
                    IOSAppLocalization.formatted(
                        "深度阅读已生成，但部分段落未完成（%@），可重新生成。",
                        defaultValue: "深度阅读已生成，但部分段落未完成（%@），可重新生成。",
                        arguments: [missingSections.joined(separator: "、")]
                    ),
                    true
                )
            }
        } catch {
            let message = IOSDeepReadUserFacingText.fromError(error)
            guard store.markWorkspaceSyncFailed(id: taskId, message: message) else {
                reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
                return true // The article itself is already durable.
            }
            onStatus?(
                IOSAppLocalization.formatted(
                    "深度阅读已生成，但保存到 Workspace 失败：%@",
                    defaultValue: "深度阅读已生成，但保存到 Workspace 失败：%@",
                    arguments: [message]
                ),
                true
            )
        }
        return true
    }

    static func retryWorkspaceSync(
        taskId: String,
        store: IOSDeepReadStore = .shared,
        workspaceStore: IOSWorkspaceStore = .shared,
        workspaceArtifactSaver: WorkspaceArtifactSaver? = nil,
        onStatus: StatusHandler
    ) {
        guard let task = store.task(id: taskId) else {
            onStatus(IOSAppLocalization.string("深度阅读记录不存在。", defaultValue: "深度阅读记录不存在。"), true)
            return
        }
        guard task.workspaceSyncFailed != nil else {
            if let message = store.persistenceError(for: taskId) {
                onStatus(message, true)
            } else {
                onStatus(IOSAppLocalization.string("已保存到 Workspace", defaultValue: "已保存到 Workspace"), false)
            }
            return
        }
        do {
            // A previous payload save may have succeeded while clearing its
            // warning failed. Check that exact article even after relaunch.
            var alreadySaved = false
            for artifact in workspaceStore.artifacts where artifact.sourceKind == "deep_read"
                && artifact.sourceId == task.id && artifact.title == task.title {
                let content = try workspaceStore.artifactContent(id: artifact.id)
                if content.utf8.elementsEqual(task.resultMarkdown.utf8) {
                    alreadySaved = true
                    break
                }
            }
            if !alreadySaved {
                if let workspaceArtifactSaver {
                    try workspaceArtifactSaver(task.title, task.resultMarkdown, .deepRead, "deep_read", task.id)
                } else {
                    _ = try workspaceStore.saveArtifact(
                        title: task.title, content: task.resultMarkdown, type: .deepRead,
                        sourceKind: "deep_read", sourceId: task.id
                    )
                }
            }
            if store.clearWorkspaceSyncFailure(id: task.id) {
                onStatus(IOSAppLocalization.string("已保存到 Workspace", defaultValue: "已保存到 Workspace"), false)
            } else {
                onStatus(store.persistenceError(for: task.id) ?? IOSDeepReadStoreError.persistenceFailed.localizedDescription, true)
            }
        } catch {
            let message = IOSDeepReadUserFacingText.fromError(error)
            if store.markWorkspaceSyncFailed(id: task.id, message: message) {
                onStatus(IOSAppLocalization.formatted(
                    "保存到 Workspace 失败：%@", defaultValue: "保存到 Workspace 失败：%@", arguments: [message]
                ), true)
            } else {
                onStatus(store.persistenceError(for: task.id) ?? IOSDeepReadStoreError.persistenceFailed.localizedDescription, true)
            }
        }
    }

    private static func defaultWorkspaceArtifactSaver(
        title: String,
        content: String,
        type: IOSWorkspaceArtifactType,
        sourceKind: String,
        sourceId: String?
    ) throws {
        _ = try IOSWorkspaceStore.shared.saveArtifact(
            title: title,
            content: content,
            type: type,
            sourceKind: sourceKind,
            sourceId: sourceId
        )
    }

    private enum CloseReadingOutcome {
        case completed(markdown: String, json: String?, missing: [String])
        case failed(String)
        case persistenceFailed
        case aborted
    }

    /// Close reading: the primary text is read in full, numbered and annotated, then compared
    /// with other reports on the same story (the task's other sources plus a title search).
    private static func generateCloseReading(
        task: IOSDeepReadTask,
        primaryIndex: Int,
        resolved: (model: Model, provider: ProviderSetting)?,
        keepsPriorGuide: Bool,
        settings: Settings?,
        store: IOSDeepReadStore,
        textProvider: any IOSAgentTextProvider,
        isCurrentRun: @escaping @MainActor () -> Bool,
        progress: @escaping (_ completed: Int64, _ label: String, _ total: Int64?) -> Void,
        stage: (_ stage: AgentActivityStage, _ detail: String?) -> Void,
        fetchPrimary: PrimaryFetch,
        searchReports: SourceSearch,
        enrichSources: SourceEnrichment
    ) async -> CloseReadingOutcome {
        let taskId = task.id
        var primary = task.sources[primaryIndex]
        var page = DeepReadCloseReader.Page(title: primary.title, text: primary.content,
                                            heroImageURL: primary.metadata["hero_image_url"])
        if let url = primary.url, primary.metadata["scrape_status"] != "ok" {
            progress(1, IOSAppLocalization.string("正在抓取原文正文", defaultValue: "正在抓取原文正文"), 6)
            stage(.readingWeb, AgentActivityStepDetailPolicy.webDetail(url: url))
            do {
                page = try await fetchPrimary(url, settings)
            } catch {
                guard isCurrentRun() else { return .aborted }
                return .failed(IOSAppLocalization.formatted(
                    "原文读取失败：%@", defaultValue: "原文读取失败：%@",
                    arguments: [IOSDeepReadUserFacingText.fromError(error)]
                ))
            }
            guard isCurrentRun() else { return .aborted }
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
            return .failed(IOSAppLocalization.string("原文没有可读的正文。", defaultValue: "原文没有可读的正文。"))
        }
        let site = DeepReadCloseReader.siteName(primary.url) ?? primary.title
        if primary.metadata[DeepReadCloseReader.originalOnlyKey] == "true" {
            var sources = task.sources
            sources[primaryIndex] = primary
            guard store.replaceSources(id: taskId, sources: sources) else { return .persistenceFailed }
            let reading = DeepReadCloseReader.unannotated(page: page, url: primary.url, site: site, paragraphs: paragraphs)
            return .completed(markdown: DeepReadCloseReader.markdown(reading), json: reading.encoded(), missing: [])
        }
        guard let resolved else {
            return .failed(IOSAppLocalization.string(
                "深度阅读生成失败：请在深度阅读设置中选择可用模型，并检查服务商登录状态。",
                defaultValue: "深度阅读生成失败：请在深度阅读设置中选择可用模型，并检查服务商登录状态。"
            ))
        }

        // Other reports: the task's remaining sources plus a search on the article's title.
        progress(2, IOSAppLocalization.string("正在抓取其他报道", defaultValue: "正在抓取其他报道"), 6)
        stage(.searching, nil)
        let searchTitle = store.task(id: taskId)?.title ?? task.title
        let searched = await searchReports(searchTitle, settings)
        guard isCurrentRun() else { return .aborted }
        let primaryURL = primary.url
        let inputs = task.sources.filter { !DeepReadCloseReader.isPrimary($0) }
        // The title search usually finds the original itself, often under another URL form.
        let candidates = Array(DeepReadSourceCollector.dedupe(inputs + searched)
            .filter { $0.url != nil && !DeepReadCloseReader.sameArticle($0.url, primaryURL) && $0.metadata["scrape_status"] != "failed" }
            .prefix(DeepReadCloseReader.maxOtherReports))
        let enriched = await enrichSources(candidates, settings, { index, total in
            progress(2, "\(IOSAppLocalization.string("正在抓取其他报道", defaultValue: "正在抓取其他报道")) \(index)/\(total)", nil)
        })
        guard isCurrentRun() else { return .aborted }
        // The task's other inputs that were not compared this time stay for later retries;
        // search results that could not be read are dropped so a retry can find and scrape them again.
        let compared = Set(candidates.map(\.id))
        let kept = [primary] + (enriched + inputs.filter { !compared.contains($0.id) })
            .filter { !($0.metadata["search_query"] != nil && $0.metadata["scrape_status"] == "failed") }
        guard store.replaceSources(id: taskId, sources: kept) else { return .persistenceFailed }

        progress(3, IOSAppLocalization.string("正在生成导读与批注", defaultValue: "正在生成导读与批注"), nil)
        stage(.generating, nil)
        let (guideText, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
            prompt: DeepReadCloseReader.prompt(title: page.title, site: site, paragraphs: paragraphs),
            providerSetting: resolved.provider, model: resolved.model, provider: textProvider)
        guard isCurrentRun() else { return .aborted }
        // A failed guide still leaves a readable original, marked partial so a retry can fill it in;
        // a retry must not trade an existing guide for the bare original.
        let annotated = DeepReadCloseReader.parse(guideText, page: page, url: primary.url, site: site, paragraphs: paragraphs)
        if annotated == nil, keepsPriorGuide {
            return .failed(IOSAppLocalization.string(
                "导读与批注生成失败，已保留上一版精读。", defaultValue: "导读与批注生成失败，已保留上一版精读。"
            ))
        }
        var reading = annotated ?? DeepReadCloseReader.unannotated(page: page, url: primary.url, site: site, paragraphs: paragraphs)
        var missing = annotated == nil ? [DeepReadCloseReader.missingSection] : []

        let others = enriched.filter(\.hasUsableGenerationContent).enumerated()
            .map { DeepReadCloseReader.OtherInput(id: $0.offset + 1, source: $0.element) }
        // Comparison notes hang on a guided reading; without a guide the page only shows the original.
        if annotated != nil, !others.isEmpty {
            progress(4, IOSAppLocalization.string("正在生成别家说法", defaultValue: "正在生成别家说法"), nil)
            let (compareText, _) = await IOSDeepReadDraftGenerator.synthesizeJSON(
                prompt: DeepReadCloseReader.comparePrompt(reading: reading, others: others),
                providerSetting: resolved.provider, model: resolved.model, provider: textProvider)
            guard isCurrentRun() else { return .aborted }
            if let compared = DeepReadCloseReader.mergeComparison(compareText, into: reading, others: others) {
                reading = compared
            } else {
                missing.append(DeepReadCloseReader.compareMissingSection)
            }
        }
        return .completed(markdown: DeepReadCloseReader.markdown(reading), json: reading.encoded(), missing: missing)
    }

    private static func failRun(
        taskId: String,
        message: String,
        store: IOSDeepReadStore,
        onStatus: StatusHandler?,
        priorCompletion: IOSDeepReadPriorCompletion? = nil
    ) -> Bool {
        let saved: Bool
        if let priorCompletion {
            saved = restorePriorCompletion(priorCompletion, taskId: taskId, store: store)
        } else {
            saved = store.fail(id: taskId, message: message)
        }
        guard saved else {
            return reportPersistenceFailure(taskId: taskId, store: store, onStatus: onStatus)
        }
        onStatus?(message, true)
        return false
    }

    /// Reinstates the completed state captured before a retry started.
    @discardableResult
    static func restorePriorCompletion(
        _ prior: IOSDeepReadPriorCompletion,
        taskId: String,
        store: IOSDeepReadStore
    ) -> Bool {
        store.complete(
            id: taskId,
            markdown: prior.markdown,
            structuredJSON: prior.structuredJSON,
            missingSections: prior.missingSections
        )
    }

    @discardableResult
    private static func reportPersistenceFailure(
        taskId: String,
        store: IOSDeepReadStore,
        onStatus: StatusHandler?
    ) -> Bool {
        onStatus?(store.persistenceError(for: taskId) ?? IOSDeepReadStoreError.persistenceFailed.localizedDescription, true)
        return false
    }

    private static func isUsableSourceForGeneration(_ source: IOSDeepReadSource) -> Bool {
        source.hasUsableGenerationContent
    }
}

@MainActor
final class IOSDeepReadRunRegistry {
    private struct Entry {
        let generationID: UUID
        var task: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]

    var activeTaskIds: Set<String> { Set(entries.keys) }

    func reserve(taskId: String) -> UUID? {
        guard entries[taskId] == nil else { return nil }
        let generationID = UUID()
        entries[taskId] = Entry(generationID: generationID, task: nil)
        return generationID
    }

    func attach(_ task: Task<Void, Never>, taskId: String, generationID: UUID) {
        guard var entry = entries[taskId], entry.generationID == generationID else {
            task.cancel()
            return
        }
        entry.task = task
        entries[taskId] = entry
    }

    func isCurrent(taskId: String, generationID: UUID) -> Bool {
        entries[taskId]?.generationID == generationID
    }

    @discardableResult
    func cancel(taskId: String, generationID: UUID) -> Bool {
        guard let entry = entries[taskId], entry.generationID == generationID else { return false }
        entries.removeValue(forKey: taskId)
        entry.task?.cancel()
        return true
    }

    @discardableResult
    func finish(taskId: String, generationID: UUID) -> Bool {
        guard entries[taskId]?.generationID == generationID else { return false }
        entries.removeValue(forKey: taskId)
        return true
    }
}

struct IOSDeepReadExpirationHandlers {
    let onShortWindowExpiration: (() -> Void)?
    let onSystemTaskExpiration: () -> Void

    static func cancelOwnerOnlyOnSystemExpiration(
        _ cancelOwner: @escaping () -> Void
    ) -> IOSDeepReadExpirationHandlers {
        IOSDeepReadExpirationHandlers(
            onShortWindowExpiration: nil,
            onSystemTaskExpiration: cancelOwner
        )
    }
}

/// Starts deep-read generation immediately in-process and holds background
/// execution rights via `BackgroundGenerationKeepAlive` (same pattern as
/// chat / council / novel). Does not host the pipeline inside a BG handler.
@MainActor
final class IOSDeepReadBackgroundCoordinator {
    static let shared = IOSDeepReadBackgroundCoordinator()

    private var sharedSettings: IOSSharedSettingsStore?
    private let runRegistry = IOSDeepReadRunRegistry()
    private let durableRunStore = IOSDurableRunStore()

    private init() {}

    func configure(sharedSettings: IOSSharedSettingsStore) {
        self.sharedSettings = sharedSettings
    }

    /// Task ids currently generating in this process (for cold-start recovery exclusion).
    var activeTaskIds: Set<String> {
        runRegistry.activeTaskIds.union(BackgroundGenerationKeepAlive.shared.activeLeaseIds)
    }

    func start(
        taskId: String,
        title: String,
        sharedSettings: IOSSharedSettingsStore,
        targetStages: Set<String>? = nil,
        initialOutput: IOSDeepReadOutput? = nil,
        priorCompletion: IOSDeepReadPriorCompletion? = nil,
        onStatus: @escaping IOSDeepReadLauncher.StatusHandler
    ) {
        configure(sharedSettings: sharedSettings)
        guard let generationID = runRegistry.reserve(taskId: taskId) else { return }
        let durableRunId = "\(taskId):\(generationID.uuidString)"

        // System continued-processing cancellation is a real ownership stop.
        // The UIKit short window is not an authoritative run-owner signal; its
        // deadline may lapse while the in-process run remains valid. It therefore
        // intentionally has no cancellation callback.
        let interruptMessage = IOSAppLocalization.string(
            "后台生成被系统中断，可稍后重试。",
            defaultValue: "后台生成被系统中断，可稍后重试。"
        )
        let failIfInterrupted: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.runRegistry.cancel(taskId: taskId, generationID: generationID) else { return }
                if let task = IOSDeepReadStore.shared.task(id: taskId),
                   task.status == .running || task.status == .queued {
                    if let priorCompletion {
                        IOSDeepReadLauncher.restorePriorCompletion(
                            priorCompletion, taskId: taskId, store: .shared
                        )
                    } else {
                        IOSDeepReadStore.shared.fail(id: taskId, message: interruptMessage)
                    }
                    onStatus(IOSDeepReadStore.shared.persistenceError(for: taskId) ?? interruptMessage, true)
                }
                await AgentLiveActivityController.shared.end(runId: durableRunId, presentation: .failed())
                _ = try? await self.durableRunStore.transitionFromAnyActive(
                    runId: durableRunId,
                    to: .interrupted,
                    detail: "background_expiration"
                )
            }
        }
        let expirationHandlers = IOSDeepReadExpirationHandlers.cancelOwnerOnlyOnSystemExpiration(
            failIfInterrupted
        )

        BackgroundGenerationKeepAlive.shared.begin(
            taskId,
            title: IOSAppLocalization.string("深度阅读", defaultValue: "深度阅读"),
            subtitle: title,
            onExpire: expirationHandlers.onShortWindowExpiration,
            onSystemTaskExpiration: expirationHandlers.onSystemTaskExpiration
        )
        BackgroundGenerationKeepAlive.shared.updateProgress(
            taskId,
            completed: 0,
            total: 7,
            subtitle: IOSAppLocalization.string("准备生成", defaultValue: "准备生成")
        )
        startLiveActivity(runId: durableRunId, taskId: taskId, title: title)
        // 生成阶段一次可跑好几分钟、期间没有新状态；进程还在执行就按间隔续期，
        // 否则 180 秒后卡片会被系统标成「后台暂停」。App 被挂起时这里不跑，照常过期。
        let liveActivityHeartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AgentActivityLifecyclePolicy.progressRefreshInterval))
                AgentLiveActivityController.shared.noteProgress(runId: durableRunId)
            }
        }

        let operationTask = Task { @MainActor [weak self] in
            var didSucceed = false
            defer { liveActivityHeartbeat.cancel() }
            guard let self else { return }
            defer {
                if self.runRegistry.finish(taskId: taskId, generationID: generationID) {
                    BackgroundGenerationKeepAlive.shared.end(taskId)
                }
                // 系统中断已在 failIfInterrupted 里收起卡片，这里再调一次是空操作。
                let terminal: AgentActivityPresentation = didSucceed ? .completed() : .failed()
                Task { @MainActor in
                    await AgentLiveActivityController.shared.end(runId: durableRunId, presentation: terminal)
                }
            }
            let didStartDurably = (try? await self.durableRunStore.ensureRunning(
                runId: durableRunId,
                descriptorId: IOSDurableRunStore.Descriptor.deepRead,
                startedAt: Int64(Date().timeIntervalSince1970 * 1_000),
                inputDigest: IOSDurableRunStore.inputDigest(title),
                inputSnapshotRef: "deep_read:\(taskId)"
            )) == true
            guard self.runRegistry.isCurrent(taskId: taskId, generationID: generationID) else {
                _ = try? await self.durableRunStore.transitionFromAnyActive(
                    runId: durableRunId,
                    to: .interrupted,
                    detail: "background_expiration"
                )
                return
            }
            guard didStartDurably else {
                let message = IOSAppLocalization.string(
                    "无法保存运行状态，深度阅读未启动。",
                    defaultValue: "无法保存运行状态，深度阅读未启动。"
                )
                if let priorCompletion {
                    IOSDeepReadLauncher.restorePriorCompletion(
                        priorCompletion, taskId: taskId, store: .shared
                    )
                } else {
                    IOSDeepReadStore.shared.fail(id: taskId, message: message)
                }
                onStatus(IOSDeepReadStore.shared.persistenceError(for: taskId) ?? message, true)
                return
            }
            didSucceed = await IOSDeepReadLauncher.runExistingTask(
                taskId: taskId,
                sharedSettings: sharedSettings,
                onStatus: onStatus,
                isCurrentRun: { [weak self] in
                    guard !Task.isCancelled, let self else { return false }
                    return self.runRegistry.isCurrent(taskId: taskId, generationID: generationID)
                },
                targetStages: targetStages,
                initialOutput: initialOutput,
                priorCompletion: priorCompletion,
                onActivityStage: { stage, detail in
                    Task { @MainActor in
                        await AgentLiveActivityController.shared.update(
                            runId: durableRunId,
                            presentation: .deepRead(stage: stage, detail: detail)
                        )
                    }
                }
            )
            // Expiration removes the registry owner and owns the interrupted
            // settlement above; do not race it with a generic failed mapping.
            guard self.runRegistry.isCurrent(taskId: taskId, generationID: generationID) else { return }
            _ = try? await self.durableRunStore.transitionFromAnyActive(
                runId: durableRunId,
                to: didSucceed ? .completed : .failed,
                detail: IOSDeepReadStore.shared.persistenceError(for: taskId)
                    ?? IOSDeepReadStore.shared.task(id: taskId)?.failureMessage
            )
        }
        runRegistry.attach(operationTask, taskId: taskId, generationID: generationID)
    }

    /// 灵动岛卡片与聊天共用「灵动岛实时活动」开关和控制器；没有对话，点按打开这篇深度阅读。
    private func startLiveActivity(runId: String, taskId: String, title: String) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: IOSExecutionPreferenceKeys.liveActivity) != nil,
           !defaults.bool(forKey: IOSExecutionPreferenceKeys.liveActivity) {
            return
        }
        AgentLiveActivityController.shared.start(
            runId: runId,
            conversationId: nil,
            conversationTitle: title,
            deepReadTaskId: taskId,
            presentation: .deepRead(stage: .preparing)
        )
    }

    func reconcileDurableRuns() async {
        guard let runs = try? await durableRunStore.recoverableRuns(
            descriptorIds: [IOSDurableRunStore.Descriptor.deepRead]
        ) else { return }
        for run in runs {
            guard let ref = run.inputSnapshotRef, ref.hasPrefix("deep_read:") else { continue }
            let taskId = String(ref.dropFirst("deep_read:".count))
            let task = IOSDeepReadStore.shared.task(id: taskId)
            _ = try? await durableRunStore.transitionFromAnyActive(
                runId: run.runId,
                to: Self.durableStatus(for: task?.status ?? .failed),
                detail: task?.failureMessage ?? "process_restarted"
            )
        }
    }

    private static func durableStatus(for status: IOSDeepReadTaskStatus) -> AgentRunStatus {
        switch status {
        case .succeeded:
            .completed
        case .failed, .unsupported:
            .failed
        case .queued, .running:
            .interrupted
        }
    }
}

@MainActor
enum IOSDeepReadRecoveryOnce {
    private static var didRun = false

    static func run() {
        guard !didRun else { return }
        didRun = true
        IOSDeepReadStore.shared.recoverInterruptedRuns(
            excluding: IOSDeepReadBackgroundCoordinator.shared.activeTaskIds
        )
        Task { @MainActor in
            await IOSDeepReadBackgroundCoordinator.shared.reconcileDurableRuns()
        }
    }
}

/// The manual "自定义来源" deep-read create form. Moved out of BoardView and
/// presented from Deep Read settings (BoardSettingsView) so the main Deep Read
/// page stays focused on the hot list. Self-contained: own form state + file /
/// WebMount / search sources, all funneled through `IOSDeepReadLauncher`.
struct DeepReadCreateView: View {
    let sharedSettings: IOSSharedSettingsStore

    @Environment(RouterPath.self) private var router
    @Environment(IOSConversationStore.self) private var conversationStore
    @Environment(DocumentAccessStore.self) private var documentStore
    @Environment(\.dismiss) private var dismiss

    @State private var deepReadTitle = ""
    @State private var manualText = ""
    @State private var searchQuery = ""
    @State private var selectedTemplateId = IOSDeepReadTemplate.defaultId
    @State private var isCreatingDeepRead = false
    @State private var deepReadMessage: String?
    @State private var deepReadMessageIsError = false
    @State private var isImportingDeepReadFile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                createSection
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(AmberTheme.background.ignoresSafeArea())
            .navigationTitle("自定义来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isImportingDeepReadFile,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleDeepReadFileImport(result)
            }
        }
        .presentationDetents([.large])
        .onAppear {
            selectedTemplateId = IOSDeepReadTemplate.normalizedTemplateId(sharedSettings.todayBoard.deepReadTemplateId)
        }
    }

    private var createSection: some View {
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

                    Picker("版式", selection: $selectedTemplateId) {
                        ForEach(IOSDeepReadTemplate.builtIns) { template in
                            Text(verbatim: IOSAppLocalization.string(template.name, defaultValue: template.name))
                                .tag(template.id)
                        }
                    }
                    .pickerStyle(.segmented)

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
                            .accessibilityLabel("从文件创建深度阅读")

                            Button {
                                Task { await createFromWebMount() }
                            } label: {
                                Image(systemName: "globe")
                                    .frame(width: 42)
                            }
                            .buttonStyle(.glass)
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

    private func deepReadTextField(
        title: LocalizedStringKey,
        text: Binding<String>,
        placeholder: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AmberTheme.foreground)
                .frame(width: 48, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.footnote)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AmberTheme.surface2.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func launch(title: String, sources: [IOSDeepReadSource], templateId: String) throws {
        try IOSDeepReadLauncher.createAndGenerate(
            title: title,
            sources: sources,
            templateId: templateId,
            sharedSettings: sharedSettings,
            navigate: { router.navigate(to: .deepReadTask(id: $0)) },
            onStatus: { deepReadMessage = $0; deepReadMessageIsError = $1 }
        )
        dismiss()
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
            if includeConversation, let source = try? conversationStore.currentConversationDeepReadSource() {
                sources.append(source)
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
                    sources.append(try IOSDeepReadSourceNormalizer.searchFailureSource(
                        query: searchQuery,
                        error: IOSDeepReadUserFacingText.fromError(error)
                    ))
                }
            }
            try launch(title: deepReadTitle, sources: sources, templateId: selectedTemplateId)
            manualText = ""
            searchQuery = ""
        } catch {
            deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
            deepReadMessageIsError = true
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
                try launch(title: source.title, sources: [source], templateId: sharedSettings.todayBoard.deepReadTemplateId)
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
                        try launch(title: source.title, sources: [source], templateId: sharedSettings.todayBoard.deepReadTemplateId)
                    } catch {
                        deepReadMessage = IOSDeepReadUserFacingText.fromError(error)
                        deepReadMessageIsError = true
                    }
                case .failure(let error):
                    deepReadMessage = error.userMessageForDeepRead
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
}
