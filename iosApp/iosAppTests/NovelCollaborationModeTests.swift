import XCTest
@testable import iosApp

final class NovelCollaborationModeTests: NovelCollaborationModeTestCase {
    func testNewProjectsDefaultToCocreationWithoutChapterPlans() throws {
        let document = try NovelTestFixtures.document()
        XCTAssertEqual(document.project.collaborationMode, .cocreation)
        XCTAssertTrue(document.project.pauseGhostwriteOnBlockingContinuity)
        XCTAssertTrue(document.chapterPlans.isEmpty)
    }

    func testLegacyProjectsDefaultPauseGhostwriteOnBlockingContinuityOn() throws {
        let document = try NovelTestFixtures.document()
        var encoded = try JSONEncoder().encode(document.project)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "pauseGhostwriteOnBlockingContinuity")
        encoded = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(NovelProjectRecord.self, from: encoded)
        XCTAssertTrue(decoded.pauseGhostwriteOnBlockingContinuity)
    }

    func testSetPauseGhostwriteOnBlockingContinuityTogglesProjectPreference() throws {
        var document = try NovelTestFixtures.document()
        XCTAssertTrue(document.project.pauseGhostwriteOnBlockingContinuity)

        document = try NovelReducer.apply(
            .setPauseGhostwriteOnBlockingContinuity(
                NovelSetPauseGhostwriteOnBlockingContinuityCommand(
                    context: NovelTestFixtures.context(
                        configRevision: document.project.configRevision
                    ),
                    projectID: document.project.id,
                    enabled: false
                )
            ),
            to: document
        ).document
        XCTAssertFalse(document.project.pauseGhostwriteOnBlockingContinuity)

        document = try NovelReducer.apply(
            .setPauseGhostwriteOnBlockingContinuity(
                NovelSetPauseGhostwriteOnBlockingContinuityCommand(
                    context: NovelTestFixtures.context(
                        configRevision: document.project.configRevision
                    ),
                    projectID: document.project.id,
                    enabled: true
                )
            ),
            to: document
        ).document
        XCTAssertTrue(document.project.pauseGhostwriteOnBlockingContinuity)
    }

    func testGhostwriteContinuityGateOnlySurfacesBlockingIssues() {
        let report = NovelContinuityAuditReport(
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            auditedChapterSelections: [],
            promptVersion: "test",
            scannedChapterCount: 1,
            chunkCount: 1,
            failedChunkCount: 0,
            issues: [
                NovelContinuityIssue(
                    id: "b1",
                    category: .identityDrift,
                    severity: .blocking,
                    summary: "严重身份漂移",
                    references: []
                ),
                NovelContinuityIssue(
                    id: "m1",
                    category: .chronology,
                    severity: .major,
                    summary: "时间线可疑",
                    references: []
                ),
                NovelContinuityIssue(
                    id: "n1",
                    category: .other,
                    severity: .minor,
                    summary: "小瑕疵",
                    references: []
                ),
            ],
            droppedIssueCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        XCTAssertEqual(
            NovelGhostwriteContinuityGate.blockingIssueSummaries(in: report),
            ["严重身份漂移"]
        )
        XCTAssertEqual(
            NovelGhostwriteContinuityGate.pauseDetail(for: report),
            "严重身份漂移"
        )
        XCTAssertEqual(
            NovelGhostwriteContinuityGate.pauseReason(for: report),
            .blockingContinuity
        )
    }

    func testGhostwriteContinuityGateTreatsIncompleteAsAdvisory() {
        let report = NovelContinuityAuditReport(
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            auditedChapterSelections: [],
            promptVersion: "test",
            scannedChapterCount: 2,
            chunkCount: 2,
            failedChunkCount: 1,
            issues: [],
            droppedIssueCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        XCTAssertNil(NovelGhostwriteContinuityGate.pauseDetail(for: report))
        XCTAssertNil(NovelGhostwriteContinuityGate.pauseReason(for: report))

        let failedWithBlocking = NovelContinuityAuditReport(
            projectID: report.projectID,
            branchID: report.branchID,
            auditedChapterSelections: [],
            promptVersion: "test",
            scannedChapterCount: 2,
            chunkCount: 2,
            failedChunkCount: 1,
            issues: [NovelContinuityIssue(
                id: "blocking",
                category: .identityDrift,
                severity: .blocking,
                summary: "候选人物身份冲突",
                references: []
            )],
            droppedIssueCount: 0,
            createdAt: report.createdAt
        )
        XCTAssertEqual(
            NovelGhostwriteContinuityGate.pauseReason(for: failedWithBlocking),
            .blockingContinuity
        )
    }

    func testUpsertConfirmAndClearChapterPlanUpdatesDigest() throws {
        var document = try NovelTestFixtures.document()
        let branchID = document.branches[0].id
        let planID = NovelChapterPlanID()
        let now = Date(timeIntervalSince1970: 1_700_000_100)

        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            planID: planID,
            status: .draft,
            outlinePlacement: "第 1 章",
            goalAndConflict: "主角必须夺回信物",
            mustHappen: ["夺回信物"],
            mustNotHappen: ["暴露身份"],
            endingHook: "信物碎裂",
            visibleFacts: ["信物在祭坛下"]
        )), to: document, now: now).document

        let draft = try XCTUnwrap(document.chapterPlan(for: branchID))
        XCTAssertEqual(draft.status, .draft)
        XCTAssertNil(draft.confirmedAt)
        XCTAssertEqual(
            draft.contentDigest,
            NovelChapterPlanRecord.digest(forCanonicalPayload: draft.canonicalDigestPayload())
        )
        XCTAssertNil(document.confirmedChapterPlan(for: branchID))

        document = try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID,
            planID: planID,
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "主角必须夺回信物",
            mustHappen: ["夺回信物"],
            mustNotHappen: ["暴露身份"],
            endingHook: "信物碎裂",
            visibleFacts: ["信物在祭坛下"]
        )), to: document, now: now.addingTimeInterval(1)).document

        let confirmed = try XCTUnwrap(document.confirmedChapterPlan(for: branchID))
        XCTAssertEqual(confirmed.status, .confirmed)
        XCTAssertNotNil(confirmed.confirmedAt)
        XCTAssertEqual(confirmed.id, planID)

        document = try NovelReducer.apply(.clearChapterPlan(NovelClearChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: branchID
        )), to: document, now: now.addingTimeInterval(2)).document

        XCTAssertNil(document.chapterPlan(for: branchID))
        XCTAssertEqual(document.project.collaborationMode, .cocreation)
    }

    func testConfirmChapterPlanRequiresMustHappen() throws {
        let document = try NovelTestFixtures.document()
        XCTAssertThrowsError(try NovelReducer.apply(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: NovelTestFixtures.context(configRevision: document.project.configRevision),
            projectID: document.project.id,
            branchID: document.branches[0].id,
            planID: NovelChapterPlanID(),
            status: .confirmed,
            outlinePlacement: "第 1 章",
            goalAndConflict: "只有目标没有必发生",
            mustHappen: [],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )), to: document)) { error in
            guard case .invalidInput(let message) = error as? NovelError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("must-happen"))
        }
    }

    func testSwitchToGhostwriteRequiresPlanningPackage() throws {
        let empty = try NovelTestFixtures.document()
        XCTAssertThrowsError(try NovelReducer.apply(.setCollaborationMode(
            NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(configRevision: empty.project.configRevision),
                projectID: empty.project.id,
                branchID: empty.branches[0].id,
                mode: .ghostwrite
            )
        ), to: empty)) { error in
            guard case .invalidInput(let message) = error as? NovelError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("代笔"))
        }

        var ready = try seedGhostwriteMaterials(in: try NovelTestFixtures.document())
        ready = try NovelReducer.apply(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: NovelTestFixtures.context(configRevision: ready.project.configRevision),
            projectID: ready.project.id,
            branchID: ready.branches[0].id,
            mode: .ghostwrite
        )), to: ready).document

        XCTAssertEqual(ready.project.collaborationMode, .ghostwrite)
        XCTAssertTrue(ready.chapterPlans.isEmpty)
    }

    func testSwitchToGhostwriteRejectsNonMainBranch() throws {
        var document = try seedGhostwriteMaterials(
            in: NovelTestFixtures.documentWithForkableCheckpoint()
        )
        let mainBranch = try XCTUnwrap(document.branches.first)
        let forkedBranchID = NovelBranchID()
        document = try NovelReducer.apply(.forkBranch(
            NovelBranchTestFixtures.forkCommand(
                document: document,
                sourceBranchID: mainBranch.id,
                checkpointID: mainBranch.headCheckpointID,
                branchID: forkedBranchID,
                name: "支线"
            )
        ), to: document).document

        XCTAssertThrowsError(try NovelReducer.apply(.setCollaborationMode(
            NovelSetCollaborationModeCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                branchID: forkedBranchID,
                mode: .ghostwrite
            )
        ), to: document)) { error in
            guard case .invalidInput(let message) = error as? NovelError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("主分支"))
        }
    }

    @MainActor
    func testGhostwriteStartRechecksPlanningPackageAfterModeSwitch() async throws {
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
        let outlineID = try XCTUnwrap(document.materials.first(where: {
            $0.kind == .masterOutline && !$0.isDeleted
        })?.id)
        document = try NovelReducer.apply(.deleteMaterial(
            NovelDeleteMaterialCommand(
                context: NovelTestFixtures.context(configRevision: document.project.configRevision),
                projectID: document.project.id,
                materialID: outlineID
            )
        ), to: document).document

        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(resolvedModel: NovelResolvedModel(
            providerID: "review-provider",
            ownerProviderID: "review-owner",
            modelID: "review-model",
            wireModelID: "review-wire",
            displayName: "Review Model",
            contextWindowTokens: 128_000
        ))
        let workspace = NovelCreationViewModel(creation: DefaultNovelCreation(
            repository: repository,
            modelRunner: adapter
        ))
        await workspace.loadProjects(selecting: document.project.id)
        let session = NovelSessionViewModel(workspace: workspace)
        await session.bindToCurrentSelection()

        XCTAssertEqual(session.ghostwriteReadinessIssue, .missingMasterOutline)
        XCTAssertFalse(session.canStartGhostwriteChapter)
    }

}
