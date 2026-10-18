import XCTest
@testable import iosApp

class NovelCollaborationModeTestCase: XCTestCase {
    func makeStartArtifacts(
        document: NovelProjectDocumentV1,
        request: NovelRunRequest
    ) throws -> NovelGenerationStartArtifacts {
        let plan = try NovelInjectionPlanner.plan(
            document: document,
            request: NovelInjectionPlanningRequest(
                branchID: request.branchID,
                promptKind: .proseWholeChapter,
                userText: request.userText
            )
        )
        let injection = NovelInjectionReceiptRecord(
            id: request.injectionReceiptID,
            runID: request.id,
            projectID: request.projectID,
            branchID: request.branchID,
            plan: plan,
            overrides: .none,
            providerID: "provider-id",
            modelID: "model-id",
            parameters: [:],
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let generation = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: injection.providerID,
            modelID: injection.modelID,
            promptVersion: injection.promptVersion,
            injectionReceiptID: injection.id,
            parameters: injection.parameters,
            requestSHA256: NovelDocumentValidator.sha256(plan.canonicalInput),
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        return NovelGenerationStartArtifacts(
            injectionReceipt: injection,
            generationReceipt: generation
        )
    }

    @MainActor
    func assertGhostwriteBatchCompletes(
        targetChapterCount: Int,
        waitThroughTerminalHandoff: Bool = false
    ) async throws {
        var document = try seedGhostwriteMaterials(in: NovelTestFixtures.document())
        let branchID = try XCTUnwrap(document.branches.first?.id)
        document = try NovelReducer.apply(.setCollaborationMode(
            NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(
                    configRevision: document.project.configRevision
                ),
                projectID: document.project.id,
                branchID: branchID,
                mode: .ghostwrite
            )
        ), to: document).document

        // 宿主只 seed 一次首章合同；批内后续合同必须来自联合审查的原子轮换。
        let initialPlanID = NovelChapterPlanID()
        document = try NovelReducer.apply(.upsertChapterPlan(
            NovelUpsertChapterPlanCommand(
                context: NovelTestFixtures.context(
                    configRevision: document.project.configRevision
                ),
                projectID: document.project.id,
                branchID: branchID,
                planID: initialPlanID,
                status: .confirmed,
                outlinePlacement: "第 1 章",
                goalAndConflict: "逐章推进唯一线索",
                mustHappen: ["林晚必须留下本章独有的线索"],
                mustNotHappen: ["提前结束全书"],
                endingHook: "线索指向下一章",
                visibleFacts: []
            )
        ), to: document).document
        XCTAssertEqual(document.confirmedChapterPlan(for: branchID)?.id, initialPlanID)

        var scripts: [NovelModelScript] = []
        var evidenceTokens: [String] = []
        for chapterNumber in 1...targetChapterCount {
            let token = "batch-\(targetChapterCount)-chapter-\(chapterNumber)-evidence"
            let candidate = "第\(chapterNumber)章正文：林晚沿着旧墙前行，\(token) 终于在石缝里找到新的线索。"
                + (waitThroughTerminalHandoff && chapterNumber == 1
                    ? String(repeating: "沿墙继续追查。", count: 1_200) : "")
            evidenceTokens.append(token)
            scripts.append(NovelModelScript(steps: waitThroughTerminalHandoff && chapterNumber == 1
                ? [.pause, .replacement(candidate), .complete]
                : [.delta(candidate), .complete]))
            scripts.append(NovelModelScript(steps: [
                .delta(try makeBatchAdjudicationJSON(
                    chapterNumber: chapterNumber,
                    targetChapterCount: targetChapterCount,
                    candidate: candidate,
                    evidenceToken: token
                )),
                .complete,
            ]))
        }

        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "batch-test-provider",
                ownerProviderID: "batch-test-owner",
                modelID: "batch-test-model",
                wireModelID: "batch-test-wire",
                displayName: "Batch Test Model",
                contextWindowTokens: 128_000
            ),
            scripts: scripts
        )
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let workspace = NovelCreationViewModel(creation: DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter
        ))
        await workspace.loadProjects(selecting: document.project.id)
        let session = NovelSessionViewModel(
            workspace: workspace,
            batchPolishSettleGrace: waitThroughTerminalHandoff ? 0.05 : 5
        )
        await session.bindToCurrentSelection()

        XCTAssertTrue(session.canStartGhostwriteChapter)
        XCTAssertTrue(session.startGhostwriteChapter(targetChapterCount: targetChapterCount))

        if waitThroughTerminalHandoff {
            let requestDeadline = Date().addingTimeInterval(3)
            var firstRunID: NovelRunID?
            while Date() < requestDeadline {
                firstRunID = await adapter.requests.first?.runID
                if firstRunID != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let runID = try XCTUnwrap(firstRunID)
            // This is the original five-second grace boundary, compressed by the
            // existing Session initializer so the test does not sleep for five seconds.
            try await Task.sleep(for: .milliseconds(200))
            let beforeResume = try await repository.loadProject(id: document.project.id).document
            XCTAssertEqual(beforeResume.activeRuns.first { $0.id == runID }?.status, .running)
            let requestCountBeforeResume = await adapter.requests.count
            XCTAssertEqual(requestCountBeforeResume, 1)
            await adapter.resume(runID: runID)

            let handoffDeadline = Date().addingTimeInterval(3)
            var sawDurableCandidateDuringDrain = false
            while Date() < handoffDeadline {
                let saved = try await repository.loadProject(id: document.project.id).document
                if saved.candidates.contains(where: {
                    $0.ghostwritePlanID == initialPlanID && $0.status == .available
                }), session.terminalAwaitingRefresh,
                   session.transientTail?.runID == runID {
                    sawDurableCandidateDuringDrain = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(
                sawDurableCandidateDuringDrain,
                "The candidate must persist while the original terminal presentation is still draining."
            )
        }

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
        XCTAssertFalse(session.isGhostwriting)
        var failureMessage = ""
        if progress.phase != .waitingUser {
            let detailMessage = progress.detailMessage
            let pauseReason = progress.pauseReason
            let operationErrorMessage = session.operationErrorMessage
            let terminalAwaitingRefresh = session.terminalAwaitingRefresh
            let workspaceIsPerforming = workspace.isPerforming
            let sessionActiveRunID = session.activeRunID
            let branchActiveRunID = workspace.branchSnapshot?.branch.activeRunID
            let runStatuses = workspace.projectSnapshot?.activeRuns
                .filter { $0.branchID == branchID }
                .map { "\($0.id):\($0.status)" } ?? []
            let requestCount = await adapter.requests.count
            failureMessage = "detail=\(String(describing: detailMessage)); "
                + "pauseReason=\(String(describing: pauseReason)); "
                + "operationError=\(String(describing: operationErrorMessage)); "
                + "terminalAwaitingRefresh=\(terminalAwaitingRefresh); "
                + "workspaceIsPerforming=\(workspaceIsPerforming); "
                + "sessionActiveRunID=\(String(describing: sessionActiveRunID)); "
                + "branchActiveRunID=\(String(describing: branchActiveRunID)); "
                + "runStatuses=\(runStatuses); requestCount=\(requestCount)"
        }
        XCTAssertEqual(progress.phase, .waitingUser, failureMessage)
        XCTAssertEqual(progress.pauseReason, .batchCompleted)
        XCTAssertEqual(progress.completedChapterCount, targetChapterCount)

        let project = try XCTUnwrap(workspace.projectSnapshot)
        let branch = try XCTUnwrap(
            workspace.branchSnapshot?.branch,
            "The batch did not leave a durable branch snapshot."
        )
        let collected = project.candidates.filter { $0.status == .collected }
        XCTAssertEqual(collected.count, targetChapterCount)
        XCTAssertEqual(branch.workingChapterSelections.count, targetChapterCount)
        XCTAssertNil(project.confirmedChapterPlan(for: branchID))
        XCTAssertEqual(branch.syncStatus, .synchronized)

        // 每个 stateDelta 都用本章唯一 evidence；若宿主绕过候选证据校验，批次不会完整结束。
        for token in evidenceTokens {
            let matchingCandidates = collected.filter { $0.content.contains(token) }
            XCTAssertEqual(matchingCandidates.count, 1, "Candidate evidence is not unique: \(token)")
            let matchingEvents = project.events.filter { $0.summary.contains(token) }
            XCTAssertEqual(matchingEvents.count, 1, "State evidence did not land once: \(token)")
            XCTAssertEqual(Set(matchingEvents.map(\.id)).count, matchingEvents.count)
        }
        XCTAssertEqual(Set(collected.map(\.content)).count, targetChapterCount)

        let requests = await adapter.requests
        XCTAssertEqual(
            requests.count,
            targetChapterCount * 2,
            "Each chapter must make exactly prose + one combined adjudication request."
        )
        for chapterNumber in 2...targetChapterCount {
            let priorToken = evidenceTokens[chapterNumber - 2]
            let proseRequest = requests[(chapterNumber - 1) * 2]
            XCTAssertTrue(
                proseRequest.messages.contains {
                    $0.content.contains(
                        "第\(chapterNumber - 1)章落地 \(priorToken)。"
                    )
                },
                "The next chapter must inject the state committed by the prior adjudication."
            )
        }
    }

    func makeBatchAdjudicationJSON(
        chapterNumber: Int,
        targetChapterCount: Int,
        candidate: String,
        evidenceToken: String
    ) throws -> String {
        let nextChapterNumber = chapterNumber + 1
        var root: [String: Any] = [
            "schemaVersion": 2,
            "acceptance": [
                "schemaVersion": 2,
                "accepted": true,
                "missingMustHappen": [],
                "forbiddenViolations": [],
                "obviousRepetition": [],
                "summary": "第\(chapterNumber)章按合同完成。",
            ],
            "continuity": [
                "schemaVersion": 1,
                "consistent": true,
                "issues": [],
            ],
            "stateDelta": [
                "schemaVersion": 1,
                "stateSummary": "第\(chapterNumber)章落地 \(evidenceToken)。",
                "events": [[
                    "id": "\(evidenceToken)-event",
                    "kind": "discovery",
                    "summary": "第\(chapterNumber)章发现 \(evidenceToken)。",
                    "entityReferences": ["林晚"],
                    "evidence": evidenceToken,
                ]],
                "characterChanges": [],
                "relationshipChanges": [],
                "foreshadowingChanges": [],
                "unresolvedEntityNames": [],
                "branchOutlinePatch": "继续追查 \(evidenceToken)。",
                "settingProposals": [],
            ],
        ]

        if chapterNumber < targetChapterCount {
            root["nextPlan"] = [
                "schemaVersion": 1,
                "outlinePlacement": "第 \(nextChapterNumber) 章",
                "goalAndConflict": "围绕 \(evidenceToken) 推进下一章冲突",
                "mustHappen": ["林晚必须核对 \(evidenceToken)"],
                "mustNotHappen": ["提前结束全书"],
                "endingHook": "新的线索继续指向远方",
                "visibleFacts": [evidenceToken],
            ]
        } else {
            root["nextPlan"] = NSNull()
        }

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        // Keep the candidate argument in the helper's contract so every evidence
        // token is intentionally authored from the exact chapter body under test.
        XCTAssertTrue(candidate.contains(evidenceToken))
        return String(decoding: data, as: UTF8.self)
    }

    func seedGhostwriteMaterials(
        in document: NovelProjectDocumentV1
    ) throws -> NovelProjectDocumentV1 {
        var next = document
        next = try revise(
            next,
            kind: .masterOutline,
            title: "总纲",
            content: "全书主线：夺回失落的信物。"
        )
        next = try revise(
            next,
            kind: .character,
            title: "林晚",
            content: "冷静的女刺客，目标是找回信物。"
        )
        next = try revise(
            next,
            kind: .writingRequirements,
            title: "写作要求",
            content: "第三人称；节奏紧凑。"
        )
        return next
    }

    func revise(
        _ document: NovelProjectDocumentV1,
        kind: NovelMaterialKind,
        title: String,
        content: String
    ) throws -> NovelProjectDocumentV1 {
        try NovelReducer.apply(.reviseMaterial(NovelReviseMaterialCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            materialID: NovelMaterialID(),
            revisionID: NovelMaterialRevisionID(),
            kind: kind,
            title: title,
            content: content,
            tags: [],
            injectionMode: .always
        )), to: document).document
    }
}
