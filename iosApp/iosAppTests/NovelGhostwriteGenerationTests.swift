import XCTest
@testable import iosApp

final class NovelGhostwriteGenerationTests: NovelCollaborationModeTestCase {
    @MainActor
    func testGhostwriteSingleChapterHappyPathCollectsAndSyncs() async throws {
        // 端到端链路守护：写 → 一次联合审查并原子收录/同步/消费合同 → 完批。
        let chapterText = "林晚潜入密室，夺回了信物。\n\n她推开了封死的门，月光落在掌心。"
        let adjudicationJSON = """
        {
          "schemaVersion": 1,
          "acceptance": {
            "schemaVersion": 2,
            "accepted": true,
            "missingMustHappen": [],
            "forbiddenViolations": [],
            "obviousRepetition": [],
            "summary": "按计划完成。"
          },
          "continuity": {
            "schemaVersion": 1,
            "consistent": true,
            "issues": []
          },
          "stateDelta": {
            "schemaVersion": 1,
            "stateSummary": "林晚夺回了信物，推开了封死的门。",
            "events": [{
              "id": "door-opened",
              "kind": "discovery",
              "summary": "林晚推开了封死的门。",
              "entityReferences": ["林晚"],
              "evidence": "她推开了封死的门，月光落在掌心。"
            }],
            "characterChanges": [],
            "relationshipChanges": [],
            "foreshadowingChanges": [],
            "unresolvedEntityNames": [],
            "branchOutlinePatch": "林晚继续追查碎裂信物的来历。",
            "settingProposals": []
          }
        }
        """

        var document = try seedGhostwriteMaterials(in: NovelTestFixtures.document())
        let branchID = try XCTUnwrap(document.branches.first?.id)
        document = try NovelReducer.apply(.setCollaborationMode(
            NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                branchID: branchID,
                mode: .ghostwrite
            )
        ), to: document).document
        document = try NovelReducer.apply(.upsertChapterPlan(
            NovelUpsertChapterPlanCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                branchID: branchID,
                planID: NovelChapterPlanID(),
                status: .confirmed,
                outlinePlacement: "第 1 章",
                goalAndConflict: "夺回信物",
                mustHappen: ["夺回信物"],
                mustNotHappen: [],
                endingHook: "信物碎裂",
                visibleFacts: []
            )
        ), to: document).document

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
            scripts: [
                NovelModelScript(steps: [.delta(chapterText), .complete]),
                NovelModelScript(steps: [.delta(adjudicationJSON), .complete]),
            ]
        )
        let workspace = NovelCreationViewModel(creation: DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter
        ))
        await workspace.loadProjects(selecting: document.project.id)
        let session = NovelSessionViewModel(workspace: workspace)
        await session.bindToCurrentSelection()
        let ghostwriteLeaseID = novelGhostwriteBackgroundLeaseID(
            projectID: document.project.id,
            branchID: branchID
        )

        XCTAssertTrue(session.canStartGhostwriteChapter)
        XCTAssertTrue(session.startGhostwriteChapter(targetChapterCount: 1))
        XCTAssertTrue(BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID))

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let progress = session.ghostwriteProgress,
               progress.pauseReason != nil,
               !session.isGhostwriting {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let progress = try XCTUnwrap(session.ghostwriteProgress)
        XCTAssertEqual(progress.pauseReason, .chapterCompleted)
        XCTAssertEqual(progress.phase, .waitingUser)
        XCTAssertEqual(progress.completedChapterCount, 1)

        // 候选已自动收录、合同已消费、无操作错误残留。
        let collected = workspace.projectSnapshot?.candidates.first { $0.status == .collected }
        XCTAssertNotNil(collected)
        XCTAssertTrue(collected?.content.contains("封死的门") == true)
        XCTAssertNil(workspace.projectSnapshot?.confirmedChapterPlan(for: branchID))
        XCTAssertEqual(workspace.branchSnapshot?.branch.syncStatus, .synchronized)
        let currentStateID = try XCTUnwrap(workspace.branchSnapshot?.branch.currentStateSnapshotID)
        XCTAssertTrue(
            workspace.projectSnapshot?.stateSnapshots
                .first(where: { $0.id == currentStateID })?
                .summary.contains("夺回了信物") == true
        )
        XCTAssertNil(session.operationErrorMessage)

        // 健康路径固定两次模型调用：写稿 → 联合审查；无隐藏验收/连续性/state 调用。
        let requests = await adapter.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(BackgroundGenerationKeepAlive.shared.holdsLease(ghostwriteLeaseID))
    }

    @MainActor
    func testGhostwriteFiveChapterBatchUsesOneAdjudicationPerChapter() async throws {
        try await assertGhostwriteBatchCompletes(targetChapterCount: 5)
    }

    @MainActor
    func testGhostwriteTenChapterBatchUsesOneAdjudicationPerChapter() async throws {
        try await assertGhostwriteBatchCompletes(targetChapterCount: 10)
    }

    @MainActor
    func testGhostwriteBatchWaitsForDurableTerminalHandoffAfterLongGeneration() async throws {
        try await assertGhostwriteBatchCompletes(
            targetChapterCount: 2,
            waitThroughTerminalHandoff: true
        )
    }

    func testCollaborationModeCanSwitchBackToCocreation() throws {
        var document = try seedGhostwriteMaterials(in: try NovelTestFixtures.document())
        document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            mode: .ghostwrite
        )), to: document).document
        document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            mode: .cocreation
        )), to: document).document
        XCTAssertEqual(document.project.collaborationMode, .cocreation)
    }

    func testCannotSwitchBackToCocreationWhileBranchRunIsActive() throws {
        var document = try seedGhostwriteMaterials(in: try NovelTestFixtures.document())
        let branchID = document.branches[0].id
        document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            mode: .ghostwrite
        )), to: document).document
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "夺回信物",
            mustHappen: ["夺回信物"],
            mustNotHappen: [],
            endingHook: "信物碎裂",
            visibleFacts: []
        )), to: document).document
        let plan = try XCTUnwrap(document.confirmedChapterPlan(for: branchID))
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branchID,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "写第一章",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: NovelCandidateID(),
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            ghostwritePlanID: plan.id,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
        document = try NovelGenerationReducer.begin(
            request,
            artifacts: makeStartArtifacts(document: document, request: request),
            in: document,
            now: Date(timeIntervalSince1970: 1_700_000_200)
        ).document

        XCTAssertThrowsError(try NovelReducer.apply(.setCollaborationMode(
            NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                branchID: branchID,
                mode: .cocreation
            )
        ), to: document)) { error in
            guard case .projectBusy(let projectID) = error as? NovelError else {
                return XCTFail("Expected projectBusy, got \(error)")
            }
            XCTAssertEqual(projectID, document.project.id)
        }
    }

    func testChapterPlanCanBeRecreatedAfterClear() throws {
        var document = try NovelTestFixtures.document()
        let branchID = document.branches[0].id
        let firstID = NovelChapterPlanID()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            planID: firstID,
            status: .draft,
            outlinePlacement: "第 1 章",
            goalAndConflict: "先写一版",
            mustHappen: ["起冲突"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document).document
        document = try NovelReducer.apply(.clearChapterPlan(NovelClearChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID
        )), to: document).document
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "重拟合同",
            mustHappen: ["起冲突"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document).document
        let plan = try XCTUnwrap(document.confirmedChapterPlan(for: branchID))
        XCTAssertNotEqual(plan.id, firstID)
        XCTAssertEqual(plan.goalAndConflict, "重拟合同")
    }

    func testGhostwriteWholeChapterRequiresConfirmedPlan() throws {
        var document = try seedGhostwriteMaterials(in: try NovelTestFixtures.document())
        document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            mode: .ghostwrite
        )), to: document).document

        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "写第一章",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: NovelCandidateID(),
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
        let artifacts = try makeStartArtifacts(document: document, request: request)

        XCTAssertThrowsError(try NovelGenerationReducer.begin(
            request,
            artifacts: artifacts,
            in: document,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        )) { error in
            guard case .invalidInput(let message) = error as? NovelError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("本章计划"))
        }

        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "夺回信物",
            mustHappen: ["夺回信物"],
            mustNotHappen: [],
            endingHook: "信物碎裂",
            visibleFacts: []
        )), to: document).document

        let withPlan = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: request.branchID,
                promptKind: .proseWholeChapter,
                userText: request.userText
            )
        )
        XCTAssertTrue(withPlan.sections.contains { section in
            if case .chapterPlan = section.kind { return true }
            return false
        })
        XCTAssertTrue(withPlan.canonicalInput.contains("夺回信物"))
    }

    func testConfirmedChapterPlanInjectedOnlyForWholeChapterProse() throws {
        var document = try NovelTestFixtures.document()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 2 章",
            goalAndConflict: "谈判破裂",
            mustHappen: ["公开拒绝盟约"],
            mustNotHappen: ["私下和解"],
            endingHook: "使者离席",
            visibleFacts: ["使者带来盟约"]
        )), to: document).document

        let whole = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseWholeChapter,
                userText: "写下一章"
            )
        )
        let continuation = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: document.branches[0].id,
                promptKind: .proseContinuation,
                userText: "续写一段"
            )
        )

        XCTAssertTrue(whole.sections.contains { section in
            section.reason == .confirmedChapterPlan
        })
        XCTAssertFalse(continuation.sections.contains { section in
            section.reason == .confirmedChapterPlan
        })
    }

    func testWholeChapterProseBindsChapterPlanDigestToCandidate() throws {
        var document = try seedGhostwriteMaterials(in: try NovelTestFixtures.document())
        document = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            mode: .ghostwrite
        )), to: document).document
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "夺回信物",
            mustHappen: ["夺回信物"],
            mustNotHappen: ["暴露身份"],
            endingHook: "信物碎裂",
            visibleFacts: []
        )), to: document).document
        let plan = try XCTUnwrap(document.confirmedChapterPlan(for: document.branches[0].id))
        let candidateID = NovelCandidateID()
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "写第一章",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: candidateID,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            ghostwritePlanID: plan.id,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: document.branches[0].headRevision
        )
        let artifacts = try makeStartArtifacts(document: document, request: request)
        let started = try NovelGenerationReducer.begin(
            request,
            artifacts: artifacts,
            in: document,
            now: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertEqual(started.document.activeRuns[0].chapterPlanDigest, plan.contentDigest)
        XCTAssertEqual(started.document.activeRuns[0].ghostwritePlanID, plan.id)

        let completed = try NovelGenerationReducer.complete(
            runID: request.id,
            content: "林晚夺回了信物。\n\n信物却在掌心碎裂。",
            in: started.document,
            now: Date(timeIntervalSince1970: 1_700_000_201)
        )
        let candidate = try XCTUnwrap(completed.document.candidates.first { $0.id == candidateID })
        XCTAssertEqual(candidate.chapterPlanDigest, plan.contentDigest)
        XCTAssertEqual(candidate.ghostwritePlanID, plan.id)
        XCTAssertEqual(candidate.status, .available)
    }

    func testGhostwriteCandidateOwnershipRequiresDurablePlanIdentity() throws {
        var document = try NovelTestFixtures.document()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "相同内容",
            mustHappen: ["同一事件"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document).document
        let plan = try XCTUnwrap(document.confirmedChapterPlan(for: document.branches[0].id))
        let branch = document.branches[0]
        let session = document.sessions[0]
        func candidate(ghostwritePlanID: NovelChapterPlanID?) -> NovelCandidateRecord {
            NovelCandidateRecord(
                id: NovelCandidateID(),
                kind: .prose,
                branchID: branch.id,
                sessionID: session.id,
                sourceMessageID: NovelMessageID(),
                baseCheckpointID: branch.headCheckpointID,
                baseHeadRevision: branch.headRevision,
                status: .available,
                content: "正文",
                sourceChapterVersionID: nil,
                collectedCheckpointID: nil,
                chapterPlanDigest: plan.contentDigest,
                ghostwritePlanID: ghostwritePlanID,
                createdAt: Date()
            )
        }

        XCTAssertTrue(NovelGhostwriteCandidateOwnership.belongs(candidate(ghostwritePlanID: plan.id), to: plan))
        XCTAssertFalse(NovelGhostwriteCandidateOwnership.belongs(candidate(ghostwritePlanID: NovelChapterPlanID()), to: plan))
        XCTAssertFalse(NovelGhostwriteCandidateOwnership.belongs(candidate(ghostwritePlanID: nil), to: plan))
    }

    func testStaleCollectionBaseCannotReuseGhostwriteCandidate() {
        // 真机「赵大来了」：山呼稿 baseHead=160，分支已到 193。
        // belongs 仍成立，但再收录只会抛 staleBranchHeadRevision；继续必须重写。
        let planID = NovelChapterPlanID()
        let digest = "a6112fda5fab07b555213efd874da5ff36e36dcfc58e59d184b618d5a6ad9fe5"
        let branchID = NovelBranchID()
        let plan = NovelChapterPlanRecord(
            id: planID,
            branchID: branchID,
            status: .confirmed,
            outlinePlacement: "山呼",
            goalAndConflict: "进城",
            mustHappen: ["见旗"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: [],
            contentDigest: digest,
            updatedAt: Date(timeIntervalSince1970: 0),
            confirmedAt: Date(timeIntervalSince1970: 0)
        )
        let matching = NovelCandidateRecord(
            id: NovelCandidateID(),
            kind: .prose,
            branchID: branchID,
            sessionID: NovelSessionID(),
            sourceMessageID: NovelMessageID(),
            baseCheckpointID: NovelCheckpointID(),
            baseHeadRevision: 193,
            status: .available,
            content: "# 山呼",
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            chapterPlanDigest: digest,
            ghostwritePlanID: planID,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let stale = NovelCandidateRecord(
            id: NovelCandidateID(),
            kind: .prose,
            branchID: branchID,
            sessionID: NovelSessionID(),
            sourceMessageID: NovelMessageID(),
            baseCheckpointID: NovelCheckpointID(),
            baseHeadRevision: 160,
            status: .available,
            content: "# 山呼",
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            chapterPlanDigest: digest,
            ghostwritePlanID: planID,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let currentHead = NovelCheckpointID()
        XCTAssertTrue(
            NovelGhostwriteCandidateOwnership.canReuseForAutomaticCollect(
                matching,
                plan: plan,
                branchHeadCheckpointID: matching.baseCheckpointID,
                branchHeadRevision: 193,
                checkpoints: [],
                sourceMessage: nil,
                superseded: [],
                alreadyCollected: []
            )
        )
        XCTAssertFalse(
            NovelGhostwriteCandidateOwnership.canReuseForAutomaticCollect(
                stale,
                plan: plan,
                branchHeadCheckpointID: currentHead,
                branchHeadRevision: 193,
                checkpoints: [],
                sourceMessage: nil,
                superseded: [],
                alreadyCollected: []
            )
        )
        XCTAssertEqual(
            NovelGhostwriteCollectFailure.pauseReason(
                candidate: stale,
                branchHeadCheckpointID: currentHead,
                branchHeadRevision: 193,
                checkpoints: [],
                sourceMessage: nil
            ),
            .collectBaseStale
        )
        XCTAssertEqual(
            NovelGhostwriteCollectFailure.pauseReason(
                candidate: matching,
                branchHeadCheckpointID: matching.baseCheckpointID,
                branchHeadRevision: 193,
                checkpoints: [],
                sourceMessage: nil
            ),
            .collectFailed
        )
        XCTAssertTrue(NovelGhostwritePauseReason.collectBaseStale.requiresRewriteOnContinue)
        XCTAssertFalse(NovelGhostwritePauseReason.collectFailed.requiresRewriteOnContinue)
        XCTAssertTrue(
            NovelGhostwritePauseReason.collectBaseStale.displayMessage.contains("重写")
        )
        XCTAssertFalse(
            NovelGhostwritePauseReason.collectBaseStale.displayMessage.contains("刷新")
        )

        let progress = NovelGhostwriteProgress(
            binding: NovelSessionBinding(
                projectID: NovelProjectID(),
                branchID: branchID
            ),
            phase: .failed,
            pauseReason: .collectBaseStale,
            candidateID: stale.id,
            startedAt: Date(timeIntervalSince1970: 0),
            targetChapterCount: 5,
            completedChapterCount: 4,
            currentChapterIndex: 5
        )
        XCTAssertTrue(progress.mustRewriteCandidateOnResume)
        XCTAssertTrue(progress.shouldContinueSameBatch)
        XCTAssertTrue(progress.boardStepSummary.contains("将重写"))
    }

    func testCollectRejectsCandidateWhenChapterPlanDigestMismatches() throws {
        var document = try NovelTestFixtures.document()
        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "新合同",
            mustHappen: ["新事件"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document).document
        let branch = document.branches[0]
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        var session = document.sessions[0]
        session.messages.append(NovelSessionMessageRecord(
            id: messageID,
            sequence: Int64(session.messages.count),
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "旧合同写出的正文。",
            createdAt: Date(timeIntervalSince1970: 1_700_000_210),
            runID: NovelRunID(),
            candidateID: candidateID
        ))
        session.revision += 1
        document.sessions[0] = session
        document.candidates.append(NovelCandidateRecord(
            id: candidateID,
            kind: .prose,
            branchID: branch.id,
            sessionID: session.id,
            sourceMessageID: messageID,
            baseCheckpointID: branch.headCheckpointID,
            baseHeadRevision: branch.headRevision,
            status: .available,
            content: "旧合同写出的正文。",
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            chapterPlanDigest: "stale-digest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_210)
        ))

        let paragraphs = NovelParagraphParser.paragraphs(in: document.candidates[0].content)
        let command = NovelCollectCandidateCommand(
            context: NovelTestFixtures.context(
                projectRevision: document.project.revision,
                configRevision: document.project.configRevision,
                branchHeadRevision: branch.headRevision
            ),
            projectID: document.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            candidateID: candidateID,
            selection: NovelParagraphSelection(paragraphIDs: paragraphs.map(\.id), editedText: nil),
            target: .createNextChapter(chapterID: NovelChapterID(), title: "第 1 章"),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID(),
            source: .systemAutoCollect
        )
        XCTAssertThrowsError(try NovelFactTransactionReducer.commitCollectionWithoutStateSync(
            command,
            payloadSHA256: try command.canonicalPayloadSHA256(),
            in: document
        )) { error in
            guard case .invalidInput(let message) = error as? NovelError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("chapter plan") || message.contains("合同"))
        }
    }

    func testChapterPlanAcceptanceDecoderFailClosed() throws {
        let legacyAccepted = """
        {"schemaVersion":1,"accepted":true,"missingMustHappen":[],"forbiddenViolations":[],"summary":"合同要点均已落地。"}
        """
        let legacy = try NovelStructuredOutputDecoder.decodeChapterPlanAcceptance(from: legacyAccepted)
        XCTAssertTrue(legacy.accepted)
        XCTAssertTrue(legacy.obviousRepetition.isEmpty)

        let accepted = """
        {"schemaVersion":2,"accepted":true,"missingMustHappen":[],"forbiddenViolations":[],"obviousRepetition":[],"summary":"合同要点均已落地。"}
        """
        let ok = try NovelStructuredOutputDecoder.decodeChapterPlanAcceptance(from: accepted)
        XCTAssertTrue(ok.accepted)
        XCTAssertTrue(ok.obviousRepetition.isEmpty)

        let softGate = """
        {"schemaVersion":2,"accepted":true,"missingMustHappen":[],"forbiddenViolations":[],"obviousRepetition":["再次夺回同一信物"],"summary":"合同满足，但复读旧拍。"}
        """
        let repeated = try NovelStructuredOutputDecoder.decodeChapterPlanAcceptance(from: softGate)
        XCTAssertTrue(repeated.accepted)
        XCTAssertEqual(repeated.obviousRepetition, ["再次夺回同一信物"])

        let rejected = """
        {"schemaVersion":2,"accepted":false,"missingMustHappen":["夺回信物"],"forbiddenViolations":[],"obviousRepetition":[],"summary":"缺少必发生。"}
        """
        let bad = try NovelStructuredOutputDecoder.decodeChapterPlanAcceptance(from: rejected)
        XCTAssertFalse(bad.accepted)
        XCTAssertEqual(bad.missingMustHappen, ["夺回信物"])

        XCTAssertThrowsError(try NovelStructuredOutputDecoder.decodeChapterPlanAcceptance(from: """
        {"schemaVersion":2,"accepted":true,"missingMustHappen":["x"],"forbiddenViolations":[],"obviousRepetition":[],"summary":"矛盾"}
        """))
    }

}
