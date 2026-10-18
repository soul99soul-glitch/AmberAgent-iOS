import XCTest
@testable import iosApp

final class NovelChapterPlanProposalTests: NovelCollaborationModeTestCase {
    func testChapterPlanProposalDecoderFailClosed() throws {
        let ok = try NovelStructuredOutputDecoder.decodeChapterPlanProposal(from: """
        {
          "schemaVersion": 1,
          "outlinePlacement": "第 4 章 · 中段",
          "goalAndConflict": "揭露身份并逼主角表态",
          "mustHappen": ["身份被当众揭穿"],
          "mustNotHappen": ["主角死亡"],
          "endingHook": "门外响起脚步声",
          "visibleFacts": ["主角已知信封来源"]
        }
        """)
        XCTAssertEqual(ok.mustHappen, ["身份被当众揭穿"])
        XCTAssertEqual(ok.goalAndConflict, "揭露身份并逼主角表态")

        XCTAssertThrowsError(try NovelStructuredOutputDecoder.decodeChapterPlanProposal(from: """
        {
          "schemaVersion": 1,
          "outlinePlacement": "第 4 章",
          "goalAndConflict": "只有目标没有义务",
          "mustHappen": [],
          "mustNotHappen": [],
          "endingHook": "",
          "visibleFacts": []
        }
        """))

        XCTAssertThrowsError(try NovelStructuredOutputDecoder.decodeChapterPlanProposal(from: """
        {
          "schemaVersion": 1,
          "outlinePlacement": "第 4 章",
          "goalAndConflict": "",
          "mustHappen": ["有义务"],
          "mustNotHappen": [],
          "endingHook": "",
          "visibleFacts": []
        }
        """))
    }

    func testChapterPlanProposalDecoderAcceptsMarkdownHeadings() throws {
        let thinkingPreamble = "先想这一章该推进什么，不要重演上一章。\n\n"
        let markdown = """
        # 章名
        灯火
        # 目标
        揭露身份并逼主角表态
        # 必发生
        - 身份被当众揭穿
        1. 当众对质
        # 禁止发生
        - 主角死亡
        # 章末钩子
        门外响起脚步声
        # 可见要点
        - 主角已知信封来源
        """
        let proposal = try NovelStructuredOutputDecoder.decodeChapterPlanProposal(
            from: thinkingPreamble + markdown
        )
        XCTAssertEqual(proposal.outlinePlacement, "灯火")
        XCTAssertEqual(proposal.goalAndConflict, "揭露身份并逼主角表态")
        XCTAssertEqual(proposal.mustHappen, ["身份被当众揭穿", "当众对质"])
        XCTAssertEqual(proposal.mustNotHappen, ["主角死亡"])
        XCTAssertEqual(proposal.endingHook, "门外响起脚步声")
        XCTAssertEqual(proposal.visibleFacts, ["主角已知信封来源"])
    }

    func testChapterPlanProposalMarkdownMissingMustHappenFailsClosed() {
        XCTAssertThrowsError(try NovelStructuredOutputDecoder.decodeChapterPlanProposal(from: """
        # 章名
        灯火
        # 目标
        只有目标没有义务
        # 必发生
        # 禁止发生
        """))
    }

    func testChapterPlanProposalContextIncludesBoundedSections() throws {
        var document = try NovelTestFixtures.document()
        document = try NovelReducer.apply(.upsertUpcomingArc(NovelUpsertUpcomingArcCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            beats: ["使者身份曝光"]
        )), to: document).document
        let branch = document.branches[0]
        let context = DefaultNovelCreation.chapterPlanProposalContext(
            document: document,
            branch: branch,
            nextChapterOrdinal: 3,
            previousPlanSummary: "Placement: 第 2 章\nGoal: 试探"
        )
        XCTAssertTrue(context.contains("NEXT CHAPTER ORDINAL"))
        XCTAssertTrue(context.contains("3"))
        XCTAssertTrue(context.contains("UPCOMING ARC"))
        XCTAssertTrue(context.contains("使者身份曝光"))
        XCTAssertTrue(context.contains("PREVIOUS CHAPTER PLAN SUMMARY"))
        XCTAssertTrue(context.contains("试探"))
    }

    @MainActor
    func testProposeNextChapterPlanConfirmsMarkdownContract() async throws {
        let document = try NovelTestFixtures.document()
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "test-provider",
                ownerProviderID: "test-owner",
                modelID: "test-model",
                wireModelID: "test-wire",
                displayName: "Test Model",
                contextWindowTokens: 128_000
            ),
            scripts: [NovelModelScript(steps: [
                .reasoningDelta("先核对上一章已经落地的节拍。"),
                .delta("""
                # 章名
                灯火
                # 目标
                揭露身份并逼主角表态
                # 必发生
                - 身份被当众揭穿
                # 禁止发生
                # 章末钩子
                门外响起脚步声
                # 可见要点
                """),
                .complete,
            ])]
        )
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let plan = try await creation.proposeAndConfirmNextChapterPlan(
            projectID: document.project.id,
            branchID: document.branches[0].id,
            nextChapterOrdinal: 2,
            previousPlanSummary: "Goal: 试探"
        )
        XCTAssertEqual(plan.status, .confirmed)
        XCTAssertEqual(plan.outlinePlacement, "灯火")
        XCTAssertEqual(plan.mustHappen, ["身份被当众揭穿"])
        let persisted = try await repository.loadProject(id: document.project.id)
            .document.confirmedChapterPlan(for: document.branches[0].id)
        XCTAssertEqual(persisted?.id, plan.id)
        let requests = await adapter.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].messages.contains { $0.content.contains("# 必发生") })
        XCTAssertFalse(requests[0].messages.contains { $0.content.contains("Return only the JSON object") })
    }

    /// 草稿不算 confirmed；同 ID 可覆盖（重新生成），换 ID 则被 reducer 拒绝。
    func testChapterPlanDraftProposalDoesNotTreatAsConfirmed() throws {
        var document = try NovelTestFixtures.document()
        let branchID = document.branches[0].id
        let planID = NovelChapterPlanID()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(
                configRevision: document.project.configRevision,
                branchHeadRevision: document.branches[0].headRevision
            ),
            projectID: document.project.id,
            branchID: branchID,
            planID: planID,
            status: .draft,
            outlinePlacement: "第 1 章",
            goalAndConflict: "开局冲突",
            mustHappen: ["见面"],
            mustNotHappen: [],
            endingHook: "钩子",
            visibleFacts: []
        )), to: document).document
        XCTAssertEqual(document.chapterPlan(for: branchID)?.status, .draft)
        XCTAssertNil(document.confirmedChapterPlan(for: branchID))

        // 复用 ID 覆盖草稿（对齐 proposeNextChapterPlan 落盘策略）。
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(
                configRevision: document.project.configRevision,
                branchHeadRevision: document.branches[0].headRevision
            ),
            projectID: document.project.id,
            branchID: branchID,
            planID: planID,
            status: .draft,
            outlinePlacement: "第 1 章 · 重拟",
            goalAndConflict: "新冲突",
            mustHappen: ["重见"],
            mustNotHappen: [],
            endingHook: "新钩子",
            visibleFacts: []
        )), to: document).document
        XCTAssertEqual(document.chapterPlan(for: branchID)?.id, planID)
        XCTAssertEqual(document.chapterPlan(for: branchID)?.goalAndConflict, "新冲突")
        XCTAssertNil(document.confirmedChapterPlan(for: branchID))

        // 不同 ID 必须失败，防止双 plan 并存。
        XCTAssertThrowsError(try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(
                configRevision: document.project.configRevision,
                branchHeadRevision: document.branches[0].headRevision
            ),
            projectID: document.project.id,
            branchID: branchID,
            planID: NovelChapterPlanID(),
            status: .draft,
            outlinePlacement: "x",
            goalAndConflict: "y",
            mustHappen: ["z"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document))
    }

    func testWholeChapterHighlightsCountTowardRequiredBudget() throws {
        var document = try NovelTestFixtures.document()
        let cap = NovelStateSnapshotRecord.maxHighlightCharacterCount
        let highlights = (0..<NovelStateSnapshotRecord.maxRecentWrittenHighlights).map { index -> String in
            let prefix = String(format: "%02d-", index)
            return prefix + String(repeating: "拍", count: max(1, cap - prefix.count))
        }
        document.stateSnapshots[0] = NovelStateSnapshotRecord(
            id: document.stateSnapshots[0].id,
            eventIDs: document.stateSnapshots[0].eventIDs,
            summary: document.stateSnapshots[0].summary,
            branchOutline: document.stateSnapshots[0].branchOutline,
            unresolvedEntityNames: document.stateSnapshots[0].unresolvedEntityNames,
            createdAt: document.stateSnapshots[0].createdAt,
            recentWrittenHighlights: highlights
        )
        XCTAssertEqual(
            document.stateSnapshots[0].recentWrittenHighlights.count,
            NovelStateSnapshotRecord.maxRecentWrittenHighlights
        )

        XCTAssertThrowsError(try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseWholeChapter,
                userText: "写下一章",
                budget: NovelInjectionBudget(
                    maxEstimatedInputTokens: 2_000,
                    chapterTailCharacterLimit: 200,
                    maximumRecentSessionMessages: 0
                )
            )
        )) { error in
            guard let planningError = error as? NovelInjectionPlanningError,
                  case .requiredContentExceedsBudget(_, _, let items) = planningError else {
                return XCTFail("Expected requiredContentExceedsBudget, got \(error)")
            }
            XCTAssertTrue(items.contains(where: {
                $0.label.contains("RECENT WRITTEN BEATS")
            }))
        }
    }
}
