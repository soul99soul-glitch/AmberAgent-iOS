import XCTest
@testable import AmberDeepRead

final class DeepReadStructuredLayoutTests: XCTestCase {
    private func output(points: Int = 3) throws -> IOSDeepReadOutput {
        let corePoints = (1...points).map { #"{"point":"要点\#($0)","supporting":"支撑"}"# }.joined(separator: ",")
        let json = """
        {"summary":"导语","key_entities":["甲方","乙方"],
         "timeline":[{"date":"10月1日","event":"起因","is_highlight":false},{"date":"10月2日","event":"转折","is_highlight":true}],
         "core_points":[\(corePoints)],
         "diagram":{"type":"causal_chain","title":"因果","nodes":[{"id":"a","label":"原因"},{"id":"b","label":"经过"},{"id":"c","label":"结果"}],
                    "edges":[{"from":"a","to":"b","label":"引发"},{"from":"b","to":"c"},{"from":"a","to":"c","label":"间接影响"}]},
         "analysis":{"core_dispute":"争议","perspectives":[{"viewpoint":"观点","holder":"甲方"}]},
         "uncertainties":["比赛性质仍待足协确认"],
         "references":[{"title":"来源","url":"https://example.com/r","source":"站点"}]}
        """
        return try JSONDecoder().decode(IOSDeepReadOutput.self, from: Data(json.utf8))
    }

    private func html(_ output: IOSDeepReadOutput, order: [IOSDeepReadStructuredRenderer.Section] = IOSDeepReadStructuredRenderer.Section.standard) -> String {
        IOSDeepReadEditorialRenderer.renderHTML(.init(title: "标题", markdown: "", structured: output, sectionOrder: order))
    }

    func testSectionOrderFollowsLayout() throws {
        let page = html(try output(), order: DeepReadReaderLayout.debate.order)
        let analysis = try XCTUnwrap(page.range(of: "深度分析")).lowerBound
        let timeline = try XCTUnwrap(page.range(of: #"<p class="section">时间轴</p>"#)).lowerBound
        XCTAssertLessThan(analysis, timeline)
        XCTAssertFalse(page.contains("要点速览"), "debate layout leads with analysis, not takeaways")
    }

    func testTakeawaysNeedThreePoints() throws {
        XCTAssertTrue(html(try output(points: 3)).contains("要点速览"))
        XCTAssertFalse(html(try output(points: 2)).contains("要点速览"))
    }

    func testEntitiesAndHighlightedTimelineAreRendered() throws {
        let page = html(try output())
        XCTAssertTrue(page.contains(#"<div class="entities"><span>甲方</span><span>乙方</span></div>"#))
        XCTAssertEqual(page.components(separatedBy: #"class="timeline-item highlight""#).count - 1, 1)
    }

    func testStepDiagramKeepsOnlyNonAdjacentRelations() throws {
        let page = html(try output())
        XCTAssertTrue(page.contains(#"<p class="diagram-next">↓ 引发</p>"#))
        // a→b and b→c are implied by the step order; only a→c remains as a relation.
        let relations = try XCTUnwrap(page.range(of: #"<ul class="diagram-relations">"#).map { page[$0.upperBound...] })
        let list = relations[..<(relations.range(of: "</ul>")?.lowerBound ?? relations.endIndex)]
        XCTAssertEqual(list.components(separatedBy: "<li>").count - 1, 1)
        XCTAssertTrue(page.contains("间接影响"))
    }

    func testUncertaintiesRenderAfterAnalysisInEveryLayout() throws {
        let data = try output()
        for layout in DeepReadReaderLayout.allCases {
            let page = html(data, order: layout.order)
            let analysis = try XCTUnwrap(page.range(of: "深度分析"), "\(layout)").lowerBound
            let open = try XCTUnwrap(page.range(of: #"<p class="section">待核实</p>"#), "\(layout)").lowerBound
            XCTAssertLessThan(analysis, open, "\(layout)")
            XCTAssertTrue(page.contains("<li>比赛性质仍待足协确认</li>"))
        }
    }

    func testUncertaintiesSurviveStageMergeAndMarkdownExport() {
        var analysisStage = IOSDeepReadOutput()
        analysisStage.uncertainties = ["待确认"]
        let merged = IOSDeepReadOutput().merged(with: analysisStage)
        XCTAssertEqual(merged.uncertainties, ["待确认"], "a later stage brings its uncertainties in")
        XCTAssertEqual(merged.merged(with: IOSDeepReadOutput()).uncertainties, ["待确认"], "a later empty stage does not wipe them")
        XCTAssertTrue(IOSDeepReadDraftGenerator.markdownFromStructured(merged, title: "T", date: "D").contains("## 待核实\n- 待确认"))
    }

    func testReferencesAloneCountAsStructuredBody() {
        var output = IOSDeepReadOutput()
        output.references = [IOSDeepReadLink(title: "来源", url: "https://example.com")]
        XCTAssertTrue(output.hasStructuredBody)
    }

    func testTakeawaysKeepInlineMarkupInOneCellAndEscapeCombiningQuotes() throws {
        var data = try output()
        data.corePoints[0].point = "用 **AI** 做事"
        XCTAssertTrue(html(data).contains("<li><span>用 <strong>AI</strong> 做事</span></li>"))
        XCTAssertFalse(IOSDeepReadEditorialRenderer.esc("x\"\u{301}y").contains("\""), "a quote with a combining mark is still escaped")
    }
}
