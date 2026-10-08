import XCTest
@preconcurrency import Shared
@testable import AmberDeepRead

@MainActor
final class DeepReadSynthesisTemplateTests: XCTestCase {
    private struct EmptyCredentials: DeepReadCredentialStorage {
        func read(account: String) throws -> String? { nil }
        func write(_ value: String, account: String) throws {}
    }

    private let sources = [
        IOSDeepReadSource(kind: .searchResult, title: "报道甲", content: "甲的正文", url: "https://www.a.com/1"),
        IOSDeepReadSource(kind: .searchResult, title: "报道乙", content: "乙的正文", url: "https://b.com/2"),
    ]
    private var numbered: [(id: Int, source: IOSDeepReadSource)] { DeepReadTemplateWriter.numbered(sources) }

    private func parse(_ json: String, _ template: DeepReadSynthesisTemplate) -> DeepReadTemplateArticle? {
        DeepReadTemplateWriter.parse(json, template: template, topic: "话题", numbered: numbered)
    }

    private func html(_ article: DeepReadTemplateArticle) -> String {
        DeepReadTemplateArticleRenderer.html(article, palette: .init(accent: "#C8402F", bg: "#FBF7F1", fg: "#2A2320", surface: "#F2EADE", muted: "#6E6254", border: "#DBCEBC", dark: false),
                                             fontMode: "serif", styleCSS: "", scale: 1)
    }

    func testEachTemplateParsesItsOwnStructureAndDropsUnknownCitations() throws {
        let qa = try XCTUnwrap(parse(#"{"title":"问答","lede":"导语","questions":[{"q":"是什么？","a":"回答","sources":[1,9]},{"q":"","a":"丢弃"}]}"#, .qa))
        XCTAssertEqual(qa.qa?.map(\.sources), [[1]])
        XCTAssertEqual(qa.sources.map(\.site), ["a.com", "b.com"])

        let debate = try XCTUnwrap(parse(#"{"dispute":"争什么","camps":[{"stance":"pro","label":"支持","argument":"论点","quote":"原话","quote_by":"某人","sources":[2]},{"stance":"weird","label":"其他","argument":"论点二"}],"takeaway":"怎么看"}"#, .debate))
        XCTAssertEqual(debate.debate?.camps.map(\.stance), ["pro", "neutral"])
        XCTAssertNil(parse(#"{"camps":[{"stance":"pro","argument":"只有一方"}]}"#, .debate), "a debate needs at least two camps")

        let timeline = try XCTUnwrap(parse(#"{"events":[{"date":"1月","event":"一"},{"date":"2月","event":"二","turning":true},{"date":"3月","event":"三"}],"turns":[{"date":"2月","why":"原因"}]}"#, .timeline))
        XCTAssertEqual(timeline.timeline?.events.filter(\.turning).count, 1)

        let review = try XCTUnwrap(parse(#"{"verdict":"值得买","consensus":["续航好"],"splits":[{"topic":"影像","views":[{"source":1,"view":"提升大"},{"source":7,"view":"丢弃"}]}],"scores":[{"source":2,"score":"4/5"}]}"#, .review))
        XCTAssertEqual(review.review?.splits.first?.views.map(\.source), [1])
        XCTAssertEqual(review.review?.scores.first?.score, "4/5")

        XCTAssertNil(parse(#"{"title":"空"}"#, .brief), "a brief without points failed")
    }

    func testAutoPickFallsBackToTheMagazineWhenUnsure() {
        XCTAssertEqual(DeepReadTemplateWriter.parsePick(#"{"template":"deepread_qa","reason":"疑问多"}"#), .qa)
        XCTAssertNil(DeepReadTemplateWriter.parsePick(#"{"template":"magazine"}"#))
        XCTAssertNil(DeepReadTemplateWriter.parsePick("胡言乱语"))
        XCTAssertNil(DeepReadTemplateWriter.parsePick(#"{"template":"deepread_auto"}"#))
    }

    func testRendererShowsTemplateBlocksAndNumberedSources() throws {
        let debate = try XCTUnwrap(parse(#"{"title":"标题","dispute":"争议","camps":[{"stance":"pro","label":"甲方","argument":"论点","sources":[1]},{"stance":"con","label":"乙方","argument":"论点","sources":[2]}],"takeaway":"权衡"}"#, .debate))
        let page = html(debate)
        XCTAssertTrue(page.contains(#"<p class="kicker">观点交锋</p>"#))
        XCTAssertTrue(page.contains(#"<div class="camp con">"#))
        XCTAssertTrue(page.contains(#"<sup class="cite">[2]</sup>"#))
        XCTAssertTrue(page.contains(#"<li><span class="n">[1]</span><div><a href="https://www.a.com/1">报道甲</a>"#))
        XCTAssertTrue(DeepReadTemplateWriter.markdown(debate).contains("## 你可以怎么看"))
    }

    func testTemplateIdsSurviveTaskCreation() throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let task = try store.createTask(title: "话题", sources: sources, templateId: DeepReadSynthesisTemplate.timeline.id)
        XCTAssertEqual(task.templateId, "deepread_timeline")
        XCTAssertEqual(IOSDeepReadTemplate.normalizedTemplateId("unknown"), IOSDeepReadTemplate.magazine.id)
    }

    // MARK: Runtime

    private func runtime(_ store: IOSDeepReadStore, provider: DeepReadPipelineTests.StageProvider, templateId: String) -> DeepReadRuntime {
        let settings = DeepReadSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: EmptyCredentials())
        var model = DeepReadModelConfiguration()
        model.apiKey = "test-model-key"
        settings.models = [model]
        settings.selectedModelID = model.id
        settings.templateId = templateId
        XCTAssertTrue(settings.save(), settings.errorMessage ?? "")
        return DeepReadRuntime(settings: settings, store: store, provider: provider,
            searchSources: { _, _ in [] },
            enrichSources: { sources, _, _ in sources },
            beginBackgroundTask: { _, _ in .invalid }, endBackgroundTask: { _ in })
    }

    private func run(_ runtime: DeepReadRuntime, _ store: IOSDeepReadStore) async throws -> IOSDeepReadTask {
        let id = try runtime.create(title: "话题", sources: sources)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !runtime.activeTaskIds.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.activeTaskIds.isEmpty, "run did not finish")
        return try XCTUnwrap(store.task(id: id))
    }

    func testAutoPicksATemplateThenWritesItInOneCall() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([
            #"{"template":"deepread_brief","reason":"一般新闻"}"#,
            #"{"title":"简报标题","lede":"导语","points":["要点一","要点二"],"background":"背景","impact":"影响","uncertain":[]}"#,
        ])
        let task = try await run(runtime(store, provider: provider, templateId: DeepReadSynthesisTemplate.auto.id), store)
        XCTAssertEqual(task.status, .succeeded, task.failureMessage ?? "")
        XCTAssertEqual(provider.callCount, 2)
        let article = try XCTUnwrap(DeepReadTemplateArticle.decode(task.structuredJSON))
        XCTAssertEqual(article.kind, .brief)
        XCTAssertEqual(article.brief?.points, ["要点一", "要点二"])
        XCTAssertTrue(task.resultMarkdown.contains("## 要点"))
    }

    func testAutoChoosingTheMagazineRunsTheClassicPipeline() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([
            #"{"template":"magazine"}"#,
            #"{"overview_angle":"角度","narrative_slots":["背景"],"analysis_questions":["影响"],"stakeholders":["读者"],"risk_or_uncertainty":[],"required_source_ids":[1]}"#,
            #"{"summary":"这是一个根据多份材料生成的完整概览摘要，保留事实边界。","key_entities":["甲"]}"#,
            #"{"timeline":[{"date":"今天","event":"发生"}],"core_points":[{"point":"关键"}]}"#,
            #"{"analysis":{"core_dispute":"分歧","perspectives":[{"holder":"读者","viewpoint":"观点"}],"implications":"影响"}}"#,
            #"{"references":[{"title":"来源","url":"https://www.a.com/1","source":"甲"}]}"#,
        ])
        let task = try await run(runtime(store, provider: provider, templateId: DeepReadSynthesisTemplate.auto.id), store)
        XCTAssertEqual(task.status, .succeeded, task.failureMessage ?? "")
        XCTAssertEqual(provider.callCount, 6, "the pick plus the five-call magazine pipeline")
        XCTAssertNil(DeepReadTemplateArticle.decode(task.structuredJSON))
        XCTAssertNotNil(task.structuredJSON)
    }

    func testMagazineIsTextOnlyAndSlantKeepsItsHero() throws {
        var task = IOSDeepReadTask(id: "t", title: "标题", status: .succeeded, templateId: IOSDeepReadTemplate.magazine.id,
                                   sources: [], resultMarkdown: "# 标题\n\n正文", failureMessage: nil, createdAt: 0, updatedAt: 0,
                                   completedAt: nil, retryCount: 0)
        task.structuredJSON = #"{"summary":"导语","hero_image_url":"https://img.example.com/h.jpg"}"#
        let settings = DeepReadSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, credentials: EmptyCredentials())
        let magazine = try DeepReadArticleRenderer.html(task: task, settings: settings)
        XCTAssertFalse(magazine.contains("img.example.com/h.jpg"))
        XCTAssertTrue(magazine.contains("figure{display:none!important;}"))
        task.templateId = IOSDeepReadTemplate.editorial.id
        let slant = try DeepReadArticleRenderer.html(task: task, settings: settings)
        XCTAssertTrue(slant.contains(#"<figure class="hero"><img src="https://img.example.com/h.jpg""#))
        XCTAssertFalse(slant.contains("figure{display:none!important;}"))
    }

    func testCompletingAnAutoMagazineArticleDoesNotPickATemplateAgain() async throws {
        let store = IOSDeepReadStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let provider = DeepReadPipelineTests.StageProvider([
            #"{"analysis":{"core_dispute":"分歧","perspectives":[{"holder":"读者","viewpoint":"观点"}],"implications":"影响"}}"#,
        ])
        let runtime = runtime(store, provider: provider, templateId: DeepReadSynthesisTemplate.auto.id)
        let created = try store.createTask(title: "话题", sources: sources, templateId: DeepReadSynthesisTemplate.auto.id)
        XCTAssertTrue(store.complete(id: created.id, markdown: "# 话题", structuredJSON: #"{"summary":"已有的杂志导语","timeline":[{"date":"今天","event":"发生"}]}"#,
                                     missingSections: ["深度分析"]))
        try runtime.retry(taskId: created.id)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !runtime.activeTaskIds.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.activeTaskIds.isEmpty, "retry did not finish")
        XCTAssertFalse(provider.userPrompts.contains { $0.contains("选择最合适的深度阅读写法") }, "the magazine choice is kept")
        let task = try XCTUnwrap(store.task(id: created.id))
        XCTAssertNil(DeepReadTemplateArticle.decode(task.structuredJSON))
        XCTAssertTrue(task.structuredJSON?.contains("已有的杂志导语") == true)
    }

    func testLongTemplateFieldsRenderAsBlocksWithTrailingCitations() throws {
        let qa = try XCTUnwrap(parse(#"{"questions":[{"q":"怎么做？","a":"分两步：\n\n1. 打开\n2. 关闭","sources":[1]}]}"#, .qa))
        let page = html(qa)
        XCTAssertTrue(page.contains("<ol>"), "a list in an answer stays a list instead of breaking the paragraph")
        XCTAssertFalse(page.contains(#"<p class="a">"#))
        XCTAssertTrue(page.contains(#"<sup class="cite">[1]</sup></p>"#) || page.contains(#"<p><sup class="cite">[1]</sup></p>"#))
    }
}
