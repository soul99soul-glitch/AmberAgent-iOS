import XCTest
import UIKit
@preconcurrency import Shared
@testable import AmberDeepRead

@MainActor
final class DeepReadRuntimeTests: XCTestCase {
    private struct EmptyCredentials: DeepReadCredentialStorage {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws {}
    }

    private func settings() -> DeepReadSettingsStore {
        DeepReadSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: EmptyCredentials())
    }

    private func store() -> IOSDeepReadStore {
        IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func waitForFinish(_ runtime: DeepReadRuntime) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if runtime.activeTaskIds.isEmpty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Runtime did not finish")
    }

    private func configuredSettings() -> DeepReadSettingsStore {
        let settings = settings()
        var model = DeepReadModelConfiguration()
        model.apiKey = "test-model-key"
        settings.models = [model]
        settings.selectedModelID = model.id
        // These tests cover the classic multi-stage pipeline; new installs default to the auto template.
        settings.templateId = IOSDeepReadTemplate.magazine.id
        XCTAssertTrue(settings.save(), settings.errorMessage ?? "")
        return settings
    }

    func testSuccessfulRunCollectsGeneratesAndPersistsAllUserInputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = IOSDeepReadStore(baseDirectory: directory)
        let inputs = (1...11).map {
            IOSDeepReadSource(kind: .file, title: "材料\($0).txt", content: "用户材料正文\($0)")
        }
        let searched = IOSDeepReadSource(kind: .searchResult, title: "搜索材料", content: "搜索摘要", url: "https://example.org/article")
        let failedSearch = try IOSDeepReadSourceNormalizer.searchFailureSource(query: "一个失败角度", error: "搜索鉴权失败")
        let provider = successfulProvider()
        var receivedInputs: [IOSDeepReadSource] = []
        let runtime = DeepReadRuntime(settings: configuredSettings(), store: storage, provider: provider,
            searchSources: { title, settings in
                XCTAssertEqual(title, "阅读主题")
                XCTAssertEqual(settings?.searchCommonOptions.resultSize, 10)
                return [searched, failedSearch]
            }, enrichSources: { sources, _, progress in
                receivedInputs = sources
                let result = await DeepReadSourceCollector.enrich(sources, settings: nil, scrape: { _, _ in
                    #"{"content":"真实采集到的网页正文"}"#
                }, onSourceProgress: progress)
                return result
            }, beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        let id = try runtime.create(title: "阅读主题", sources: inputs)
        await waitForFinish(runtime)
        let task = try XCTUnwrap(storage.task(id: id))
        XCTAssertEqual(task.status, .succeeded)
        XCTAssertEqual(receivedInputs.count, 13)
        XCTAssertEqual(Array(task.sources.prefix(11)).map(\.id), inputs.map(\.id))
        XCTAssertEqual(task.sources.count, 13)
        XCTAssertTrue(task.sources.contains { $0.id == searched.id && $0.metadata["scrape_status"] == "ok" })
        XCTAssertTrue(task.sources.contains { $0.id == failedSearch.id && !$0.hasUsableGenerationContent })
        XCTAssertEqual(provider.callCount, 5)
        XCTAssertFalse(provider.userPrompts.contains { $0.contains("用户材料正文11") })
        XCTAssertFalse(provider.userPrompts.contains { $0.contains("搜索鉴权失败") })
        XCTAssertFalse(task.resultMarkdown.isEmpty)
        XCTAssertNotNil(task.structuredJSON)
        XCTAssertNil(storage.progressLabel(for: id))
        XCTAssertNil(runtime.error(for: id))
        let reloaded = IOSDeepReadStore(baseDirectory: directory)
        XCTAssertEqual(reloaded.task(id: id)?.sources, task.sources)
        XCTAssertEqual(reloaded.task(id: id)?.resultMarkdown, task.resultMarkdown)
    }

    private func successfulProvider() -> DeepReadPipelineTests.StageProvider {
        DeepReadPipelineTests.StageProvider([
            #"{"overview_angle":"来源事实解读","narrative_slots":["背景","进展"],"analysis_questions":["影响"],"stakeholders":["读者"],"risk_or_uncertainty":["待确认"],"required_source_ids":[1,2]}"#,
            #"{"summary":"这是一个根据用户提供的多份原始材料生成的完整概览摘要，保留事实边界。","key_entities":["材料"]}"#,
            #"{"timeline":[{"date":"今天","event":"材料收集完成"}],"core_points":[{"point":"关键事实"}]}"#,
            #"{"analysis":{"core_dispute":"材料之间的观点分歧","perspectives":[{"holder":"读者","viewpoint":"需要核对"}],"implications":"继续观察"}}"#,
            #"{"extended_reading":[{"title":"参考链接","url":"https://example.org","source":"来源"}],"references":[{"title":"来源","url":"https://example.org","source":"网页"}]}"#
        ])
    }

    func testTopicOnlySearchFailureIsPersistedAndDoesNotInvokeModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = IOSDeepReadStore(baseDirectory: directory)
        let provider = successfulProvider()
        let failedSearch = try IOSDeepReadSourceNormalizer.searchFailureSource(query: "阅读主题", error: "搜索鉴权失败")
        let runtime = DeepReadRuntime(settings: configuredSettings(), store: storage, provider: provider,
            searchSources: { _, _ in [failedSearch] },
            enrichSources: { sources, _, progress in
                await DeepReadSourceCollector.enrich(sources, settings: nil, scrape: { _, _ in
                    XCTFail("Topic seed and failed search must not scrape a webpage")
                    return "{}"
                }, onSourceProgress: progress)
            }, beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        let id = try runtime.create(title: "阅读主题", sources: [])
        await waitForFinish(runtime)
        let task = try XCTUnwrap(storage.task(id: id))
        XCTAssertEqual(task.status, .failed)
        XCTAssertEqual(task.sources.count, 2)
        XCTAssertTrue(task.sources.contains { $0.id == failedSearch.id && $0.content.contains("搜索鉴权失败") })
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertTrue(task.failureMessage?.contains("没有找到可用来源") == true)
        XCTAssertEqual(IOSDeepReadStore(baseDirectory: directory).task(id: id)?.sources, task.sources)
    }

    func testSuccessfulRetryReplacesOnlyPriorAutomaticSearchWarnings() async throws {
        let storage = store()
        let manual = IOSDeepReadSource(kind: .file, title: "用户材料.txt", content: "用户原始正文")
        let failedWebpage = IOSDeepReadSource(kind: .webMount, title: "用户网页", content: "读取失败", url: "https://example.org/unavailable", metadata: ["scrape_status": "failed"])
        var warning = try IOSDeepReadSourceNormalizer.searchFailureSource(query: "阅读主题", error: "上一轮搜索鉴权失败")
        warning.metadata["search_query"] = "阅读主题"
        let original = try storage.createTask(title: "阅读主题", sources: [manual, failedWebpage, warning])
        XCTAssertTrue(storage.complete(id: original.id, markdown: "旧文章"))
        let collected = IOSDeepReadSource(kind: .searchResult, title: "本轮搜索", content: "有效摘要", url: "https://example.org/new")
        let provider = successfulProvider()
        let runtime = DeepReadRuntime(settings: configuredSettings(), store: storage, provider: provider,
            searchSources: { _, _ in [collected] },
            enrichSources: { sources, _, progress in
                await DeepReadSourceCollector.enrich(sources, settings: nil, scrape: { _, _ in
                    #"{"content":"新网页正文"}"#
                }, onSourceProgress: progress)
            }, beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        try runtime.retry(taskId: original.id)
        await waitForFinish(runtime)
        let updated = try XCTUnwrap(storage.task(id: original.id))
        XCTAssertEqual(updated.status, .succeeded)
        XCTAssertEqual(updated.sources.map(\.id), [manual.id, failedWebpage.id, collected.id])
        XCTAssertEqual(updated.sources.first?.content, manual.content)
        XCTAssertEqual(updated.sources[1], failedWebpage)
        XCTAssertFalse(updated.sources.contains { $0.id == warning.id })
        XCTAssertEqual(provider.callCount, 5)
        XCTAssertFalse(provider.userPrompts.contains { $0.contains("上一轮搜索鉴权失败") })
    }

    func testMissingModelEndsWithDurableFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = IOSDeepReadStore(baseDirectory: directory)
        let runtime = DeepReadRuntime(settings: settings(), store: storage,
                                      beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        let id = try runtime.create(title: "读书", sources: [])
        await waitForFinish(runtime)
        XCTAssertEqual(storage.task(id: id)?.status, .failed)
        XCTAssertTrue(storage.task(id: id)?.failureMessage?.contains("模型") == true)
        XCTAssertNil(storage.progressLabel(for: id))
        XCTAssertNotNil(runtime.lastError)
        let reloaded = IOSDeepReadStore(baseDirectory: directory)
        XCTAssertEqual(reloaded.task(id: id)?.status, .failed)
    }

    func testCancelWritesTerminalBeforeEndingAllowance() throws {
        let storage = store()
        var terminalAtEnd: IOSDeepReadTaskStatus?
        var id: String?
        let runtime = DeepReadRuntime(settings: settings(), store: storage,
            beginBackgroundTask: { _, _ in UIBackgroundTaskIdentifier(rawValue: 41) },
            endBackgroundTask: { _ in terminalAtEnd = id.flatMap { storage.task(id: $0)?.status } })
        id = try runtime.create(title: "主题", sources: [])
        runtime.cancel(taskId: try XCTUnwrap(id))
        XCTAssertEqual(terminalAtEnd, .failed)
        XCTAssertTrue(runtime.activeTaskIds.isEmpty)
        XCTAssertTrue(storage.task(id: try XCTUnwrap(id))?.failureMessage?.contains("取消") == true)
    }

    func testExpirationPreservesPriorArticleAndEndsOwner() async throws {
        let storage = store()
        let task = try storage.createTask(title: "旧文章", sources: [.init(kind: .manualText, title: "资料", content: "正文")])
        XCTAssertTrue(storage.complete(id: task.id, markdown: "已完成的旧文章", structuredJSON: "{}", missingSections: ["分析"]))
        var completedBeforeRelease = false
        let runtime = DeepReadRuntime(settings: settings(), store: storage,
            beginBackgroundTask: { _, expiration in
                expiration()
                return UIBackgroundTaskIdentifier(rawValue: 42)
            }, endBackgroundTask: { _ in
                completedBeforeRelease = storage.task(id: task.id)?.status == .succeeded
            })
        try runtime.retry(taskId: task.id)
        await waitForFinish(runtime)
        XCTAssertTrue(completedBeforeRelease)
        XCTAssertEqual(storage.task(id: task.id)?.resultMarkdown, "已完成的旧文章")
        XCTAssertEqual(storage.task(id: task.id)?.missingSections, ["分析"])
        XCTAssertTrue(runtime.lastError?.contains("中断") == true)
    }

    func testFailedRetryKeepsExistingArticle() async throws {
        let storage = store()
        let task = try storage.createTask(title: "已有文章", sources: [.init(kind: .manualText, title: "资料", content: "正文")])
        XCTAssertTrue(storage.complete(id: task.id, markdown: "文章正文", structuredJSON: "{}", missingSections: ["时间轴"]))
        let runtime = DeepReadRuntime(settings: settings(), store: storage,
                                      beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        try runtime.retry(taskId: task.id)
        await waitForFinish(runtime)
        XCTAssertEqual(storage.task(id: task.id)?.status, .succeeded)
        XCTAssertEqual(storage.task(id: task.id)?.resultMarkdown, "文章正文")
        XCTAssertEqual(storage.task(id: task.id)?.structuredJSON, "{}")
        XCTAssertEqual(storage.task(id: task.id)?.retryCount, 1)
        XCTAssertTrue(runtime.lastError?.contains("模型") == true)
    }

    func testRecoveryMarksOrphanAndPreservesInterruptedRetryArticle() throws {
        let storage = store()
        let fresh = try storage.createTask(title: "未完成", sources: [.init(kind: .manualText, title: "资料", content: "正文")])
        let previous = try storage.createTask(title: "重试中", sources: fresh.sources)
        XCTAssertTrue(storage.complete(id: previous.id, markdown: "旧内容"))
        XCTAssertTrue(storage.prepareRetry(id: previous.id, preservingResult: true))
        let runtime = DeepReadRuntime(settings: settings(), store: storage,
                                      beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
        runtime.recoverInterruptedRuns()
        XCTAssertEqual(storage.task(id: fresh.id)?.status, .failed)
        XCTAssertEqual(storage.task(id: previous.id)?.status, .succeeded)
        XCTAssertEqual(storage.task(id: previous.id)?.resultMarkdown, "旧内容")
    }

    func testStaleExpirationDoesNotEndNewRun() async throws {
        let storage = store()
        var expirations: [@Sendable () -> Void] = []
        var endedCount = 0
        let configured = settings()
        var model = DeepReadModelConfiguration()
        model.apiKey = "test-model-key"
        configured.models = [model]
        configured.selectedModelID = model.id
        XCTAssertTrue(configured.save(), configured.errorMessage ?? "")
        // The new run stays in flight (suspended in search) while the old run's expiration fires.
        let runtime = DeepReadRuntime(settings: configured, store: storage,
            searchSources: { _, _ in try? await Task.sleep(nanoseconds: 300_000_000); return [] },
            beginBackgroundTask: { _, expiration in
                expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: expirations.count)
            }, endBackgroundTask: { _ in endedCount += 1 })
        let id = try runtime.create(title: "主题", sources: [])
        runtime.cancel(taskId: id)
        try runtime.retry(taskId: id)
        expirations[0]()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(runtime.activeTaskIds.contains(id), "the stale expiration must not end the new run")
        await waitForFinish(runtime)
        XCTAssertEqual(endedCount, 2)
        XCTAssertTrue(storage.task(id: id)?.failureMessage?.contains("没有找到可用来源") == true)
        XCTAssertFalse(runtime.lastError?.contains("中断") == true)
    }
}
