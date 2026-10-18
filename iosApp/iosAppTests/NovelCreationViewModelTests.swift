import XCTest
@testable import iosApp

@MainActor
final class NovelCreationViewModelTests: NovelCreationViewModelTestCase {
    func testDismissedChapterPlanDraftSavesOriginAfterSelectionChanges() async throws {
        let repository = InMemoryNovelProjectRepository()
        let source = try NovelTestFixtures.document()
        let other = try NovelTestFixtures.document()
        _ = try await repository.createProject(source)
        _ = try await repository.createProject(other)
        let viewModel = NovelCreationViewModel(creation: DefaultNovelCreation(repository: repository))
        let selected = await viewModel.selectProject(source.project.id)
        XCTAssertTrue(selected)
        let origin = NovelSessionBinding(projectID: source.project.id, branchID: source.branches[0].id)
        let gate = NovelPlanSaveCompletionGate()
        let priorSave = Task { @MainActor in
            let saved = await viewModel.upsertChapterPlan(
                status: .draft,
                outlinePlacement: "第一章",
                goalAndConflict: "先保存的计划",
                mustHappen: ["抵达城门"],
                mustNotHappen: [],
                endingHook: "",
                visibleFacts: []
            )
            // Commit has completed and released the selection lock, while the
            // dismissing sheet still awaits this task's return.
            await gate.suspend()
            return saved
        }
        await gate.waitUntilSuspended()
        XCTAssertFalse(viewModel.isPerforming)
        let dismissedSave = Task { @MainActor in
            _ = await priorSave.value
            return await viewModel.saveChapterPlanDraft(
                projectID: origin.projectID,
                branchID: origin.branchID,
                outlinePlacement: "第一章",
                goalAndConflict: "关闭面板前继续输入的计划",
                mustHappen: ["抵达城门", "找到线索"],
                mustNotHappen: [],
                endingHook: "旧门重新打开",
                visibleFacts: []
            )
        }
        let selectedOther = await viewModel.selectProject(other.project.id)
        XCTAssertTrue(selectedOther)
        let otherSnapshot = try XCTUnwrap(viewModel.projectSnapshot)
        await gate.resume()
        let saved = await dismissedSave.value
        XCTAssertTrue(saved, viewModel.errorMessage ?? "Source draft did not save.")
        let sourceInstalled = try await repository.loadProject(id: source.project.id).document
        let otherInstalled = try await repository.loadProject(id: other.project.id).document
        XCTAssertEqual(sourceInstalled.chapterPlan(for: origin.branchID)?.goalAndConflict, "关闭面板前继续输入的计划")
        XCTAssertEqual(otherInstalled, other)
        XCTAssertEqual(viewModel.selectedProjectID, other.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, other.branches[0].id)
        XCTAssertEqual(viewModel.projectSnapshot, otherSnapshot)
    }

    func testChapterPlanDraftSavesOriginBranchAndRefreshesCurrentProjectVersion() async throws {
        let original = try NovelTestFixtures.documentWithForkableCheckpoint()
        let originBranchID = original.branches[0].id
        let fork = NovelBranchTestFixtures.forkCommand(
            document: original,
            sourceBranchID: originBranchID,
            checkpointID: original.branches[0].headCheckpointID,
            name: "另一分支"
        )
        let document = try NovelReducer.apply(.forkBranch(fork), to: original).document
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(creation: DefaultNovelCreation(repository: repository))
        let selected = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(selected)
        _ = await viewModel.selectBranch(fork.branchID)
        let saved = await viewModel.saveChapterPlanDraft(
            projectID: document.project.id,
            branchID: originBranchID,
            outlinePlacement: "下一章",
            goalAndConflict: "原分支的草稿",
            mustHappen: ["找到线索"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )
        XCTAssertTrue(saved, viewModel.errorMessage ?? "Source branch draft did not save.")
        let installed = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(installed.chapterPlan(for: originBranchID)?.goalAndConflict, "原分支的草稿")
        XCTAssertNil(installed.chapterPlan(for: fork.branchID))
        XCTAssertEqual(viewModel.selectedBranchID, fork.branchID)
        XCTAssertEqual(viewModel.projectSnapshot?.project.configRevision, installed.project.configRevision)
        XCTAssertEqual(viewModel.branchSnapshot?.configRevision, installed.project.configRevision)
    }

    func testChapterPlanDraftSaveFailureReportsErrorWithoutChangingSelection() async throws {
        let document = try NovelTestFixtures.document()
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(creation: DefaultNovelCreation(repository: repository))
        _ = await viewModel.selectProject(document.project.id)
        let saved = await viewModel.saveChapterPlanDraft(
            projectID: NovelProjectID(),
            branchID: NovelBranchID(),
            outlinePlacement: "",
            goalAndConflict: "不能静默丢掉的草稿",
            mustHappen: ["找到线索"],
            mustNotHappen: [],
            endingHook: "",
            visibleFacts: []
        )
        XCTAssertFalse(saved)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isPerforming)
        XCTAssertEqual(viewModel.selectedProjectID, document.project.id)
        let installed = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(installed, document)
    }

    func testFailedChapterPlanDraftRemainsAvailableForReopenAndManualRetry() async throws {
        let document = try NovelTestFixtures.document()
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(creation: DefaultNovelCreation(repository: repository))
        _ = await viewModel.selectProject(document.project.id)
        let draft = NovelChapterPlanDraft(
            outlinePlacement: "第三章",
            goalAndConflict: "仍需保存的目标与冲突",
            mustHappen: ["找到线索", "打开旧门"],
            mustNotHappen: ["揭露凶手"],
            endingHook: "旧门后传来脚步",
            visibleFacts: ["城门已经关闭"]
        )
        let busyOwner = UUID()
        XCTAssertTrue(viewModel.acquireSessionOperation(ownerID: busyOwner))
        let failed = await viewModel.saveChapterPlanDraft(
            projectID: document.project.id, branchID: document.branches[0].id,
            outlinePlacement: draft.outlinePlacement, goalAndConflict: draft.goalAndConflict,
            mustHappen: draft.mustHappen, mustNotHappen: draft.mustNotHappen,
            endingHook: draft.endingHook, visibleFacts: draft.visibleFacts
        )
        XCTAssertFalse(failed)
        XCTAssertNotNil(viewModel.errorMessage)
        viewModel.releaseSessionOperation(ownerID: busyOwner)
        let recovered = try XCTUnwrap(viewModel.chapterPlanDraft(
            projectID: document.project.id, branchID: document.branches[0].id
        ))
        XCTAssertEqual(recovered, draft, "Reopening the original owner must recover all six fields.")
        XCTAssertNil(viewModel.chapterPlanDraft(projectID: NovelProjectID(), branchID: document.branches[0].id))
        XCTAssertNil(viewModel.chapterPlanDraft(projectID: document.project.id, branchID: NovelBranchID()))
        let storedBeforeRetry = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(storedBeforeRetry, document)
        let retried = await viewModel.saveChapterPlanDraft(
            projectID: document.project.id, branchID: document.branches[0].id,
            outlinePlacement: recovered.outlinePlacement, goalAndConflict: recovered.goalAndConflict,
            mustHappen: recovered.mustHappen, mustNotHappen: recovered.mustNotHappen,
            endingHook: recovered.endingHook, visibleFacts: recovered.visibleFacts
        )
        XCTAssertTrue(retried, viewModel.errorMessage ?? "Manual retry failed.")
        XCTAssertNil(viewModel.chapterPlanDraft(projectID: document.project.id, branchID: document.branches[0].id))
        let installed = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(installed.chapterPlan(for: document.branches[0].id)?.goalAndConflict, draft.goalAndConflict)
    }

    func testOlderChapterPlanSaveDoesNotReplaceOrClearNewerRetainedDraft() async throws {
        let document = try NovelTestFixtures.document()
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let blocking = BranchSnapshotBlockingNovelCreation(
            base: DefaultNovelCreation(repository: repository), blockedBranchID: NovelBranchID()
        )
        let viewModel = NovelCreationViewModel(creation: blocking)
        _ = await viewModel.selectProject(document.project.id)
        let older = NovelChapterPlanDraft(
            outlinePlacement: "第三章", goalAndConflict: "先关闭的草稿", mustHappen: ["找到线索"],
            mustNotHappen: [], endingHook: "", visibleFacts: []
        )
        let newer = NovelChapterPlanDraft(
            outlinePlacement: "第三章", goalAndConflict: "重开面板后继续改的草稿", mustHappen: ["找到线索", "打开旧门"],
            mustNotHappen: [], endingHook: "脚步声", visibleFacts: []
        )
        viewModel.retainChapterPlanDraft(older, projectID: document.project.id, branchID: document.branches[0].id)
        let gate = NovelPlanSaveCompletionGate()
        await blocking.blockNextProjectSnapshot(using: gate)
        let save = Task { @MainActor in
            await viewModel.saveChapterPlanDraft(
                projectID: document.project.id, branchID: document.branches[0].id,
                outlinePlacement: older.outlinePlacement, goalAndConflict: older.goalAndConflict,
                mustHappen: older.mustHappen, mustNotHappen: older.mustNotHappen,
                endingHook: older.endingHook, visibleFacts: older.visibleFacts,
                retainingDraft: false
            )
        }
        await gate.waitUntilSuspended()
        viewModel.retainChapterPlanDraft(newer, projectID: document.project.id, branchID: document.branches[0].id)
        await gate.resume()
        let saved = await save.value
        XCTAssertTrue(saved)
        XCTAssertEqual(viewModel.chapterPlanDraft(projectID: document.project.id, branchID: document.branches[0].id), newer)
        let installed = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(installed.chapterPlan(for: document.branches[0].id)?.goalAndConflict, older.goalAndConflict)
    }

    func testSessionOperationRequiresTheMatchingOwnerToReleaseBusyState() {
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        let ownerID = UUID()

        XCTAssertTrue(viewModel.acquireSessionOperation(ownerID: ownerID))
        XCTAssertTrue(viewModel.isPerforming)
        XCTAssertFalse(viewModel.acquireSessionOperation(ownerID: UUID()))

        viewModel.releaseSessionOperation(ownerID: UUID())
        XCTAssertTrue(viewModel.isPerforming)

        viewModel.releaseSessionOperation(ownerID: ownerID)
        XCTAssertFalse(viewModel.isPerforming)
    }

    func testProjectSelectionPublishesProjectAndBranchAsOneSnapshot() async throws {
        let repository = InMemoryNovelProjectRepository()
        let firstDocument = try NovelTestFixtures.document()
        let secondDocument = try NovelTestFixtures.document()
        _ = try await repository.createProject(firstDocument)
        _ = try await repository.createProject(secondDocument)
        let blockingCreation = BranchSnapshotBlockingNovelCreation(
            base: DefaultNovelCreation(repository: repository),
            blockedBranchID: try XCTUnwrap(secondDocument.branches.first?.id)
        )
        let viewModel = NovelCreationViewModel(creation: blockingCreation)
        let didSelectFirstProject = await viewModel.selectProject(firstDocument.project.id)
        XCTAssertTrue(didSelectFirstProject)

        let selection = Task { @MainActor in
            _ = await viewModel.selectProject(secondDocument.project.id)
        }
        await blockingCreation.waitUntilBranchSnapshotRequested()

        XCTAssertEqual(viewModel.selectedProjectID, firstDocument.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, firstDocument.branches.first?.id)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, firstDocument.project.id)
        XCTAssertEqual(viewModel.branchSnapshot?.projectID, firstDocument.project.id)

        await blockingCreation.resumeBranchSnapshot()
        await selection.value

        XCTAssertEqual(viewModel.selectedProjectID, secondDocument.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, secondDocument.branches.first?.id)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, secondDocument.project.id)
        XCTAssertEqual(viewModel.branchSnapshot?.projectID, secondDocument.project.id)
    }

    func testCancelledProjectSelectionKeepsTheCurrentCompleteSnapshot() async throws {
        let repository = InMemoryNovelProjectRepository()
        let firstDocument = try NovelTestFixtures.document()
        let secondDocument = try NovelTestFixtures.document()
        _ = try await repository.createProject(firstDocument)
        _ = try await repository.createProject(secondDocument)
        let blockingCreation = BranchSnapshotBlockingNovelCreation(
            base: DefaultNovelCreation(repository: repository),
            blockedBranchID: try XCTUnwrap(secondDocument.branches.first?.id)
        )
        let viewModel = NovelCreationViewModel(creation: blockingCreation)
        let didSelectFirstProject = await viewModel.selectProject(firstDocument.project.id)
        XCTAssertTrue(didSelectFirstProject)

        let selection = Task { @MainActor in
            await viewModel.selectProject(secondDocument.project.id)
        }
        await blockingCreation.waitUntilBranchSnapshotRequested()
        selection.cancel()
        await blockingCreation.resumeBranchSnapshot()

        let didSelectSecondProject = await selection.value
        XCTAssertFalse(didSelectSecondProject)
        XCTAssertEqual(viewModel.selectedProjectID, firstDocument.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, firstDocument.branches.first?.id)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, firstDocument.project.id)
        XCTAssertEqual(viewModel.branchSnapshot?.projectID, firstDocument.project.id)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancelledProjectListLoadDoesNotPublishStaleProjectsOrAnError() async throws {
        let repository = InMemoryNovelProjectRepository()
        let storedDocument = try NovelTestFixtures.document()
        let existingPresentation = try NovelTestFixtures.document()
        _ = try await repository.createProject(storedDocument)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        await creation.gateNextProjectListSnapshot()
        let viewModel = NovelCreationViewModel(creation: creation)
        viewModel.projects = [NovelProjectSummary(document: existingPresentation)]

        let load = Task { @MainActor in
            await viewModel.loadProjects(restoresSelection: false)
        }
        await creation.waitUntilProjectListSnapshotRequested()
        load.cancel()
        await creation.releaseProjectListSnapshot()
        await load.value

        XCTAssertEqual(viewModel.projects.map(\.id), [existingPresentation.project.id])
        XCTAssertNil(viewModel.projectListLoadError)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testStaleProjectListLoadCannotClearNewerLoadingState() async {
        let creation = OrderedProjectListNovelCreation(
            base: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        let viewModel = NovelCreationViewModel(creation: creation)

        let firstLoad = Task { @MainActor in
            await viewModel.loadProjects(restoresSelection: false)
        }
        await creation.waitUntilProjectListRequest(1)

        let secondLoad = Task { @MainActor in
            await viewModel.loadProjects(restoresSelection: false)
        }
        await creation.waitUntilProjectListRequest(2)
        XCTAssertTrue(viewModel.isLoading)

        await creation.releaseProjectListRequest(1)
        await firstLoad.value

        XCTAssertTrue(
            viewModel.isLoading,
            "较早加载结束时不能提前清除仍在执行的最新加载态"
        )

        await creation.releaseProjectListRequest(2)
        await secondLoad.value
        XCTAssertFalse(viewModel.isLoading)
    }

    func testProjectListLoadFailureKeepsAnInlineRetryReasonUntilSuccess() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        await creation.failNextProjectListSnapshots(1)
        let viewModel = NovelCreationViewModel(creation: creation)

        await viewModel.loadProjects(restoresSelection: false)

        XCTAssertNotNil(viewModel.projectListLoadError)
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.clearError()
        await viewModel.loadProjects(restoresSelection: false)

        XCTAssertEqual(viewModel.projects.map(\.id), [document.project.id])
        XCTAssertNil(viewModel.projectListLoadError)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testReloadingTheSelectedProjectKeepsItsCurrentActiveBranch() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let sourceBranchID = try XCTUnwrap(viewModel.selectedBranchID)
        let createdForkID = await viewModel.forkBranch(
            from: sourceBranchID,
            checkpointID: document.branches[0].headCheckpointID,
            name: "支线"
        )
        let forkID = try XCTUnwrap(createdForkID)
        XCTAssertEqual(viewModel.selectedBranchID, forkID)

        await viewModel.loadProjects()

        XCTAssertEqual(viewModel.selectedProjectID, document.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, forkID)
        XCTAssertEqual(viewModel.branchSnapshot?.branch.id, forkID)
    }

    func testReturningToAProjectRestoresItsLastActiveBranch() async throws {
        let repository = InMemoryNovelProjectRepository()
        let first = try NovelTestFixtures.documentWithForkableCheckpoint()
        let second = try NovelTestFixtures.document()
        _ = try await repository.createProject(first)
        _ = try await repository.createProject(second)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelectFirst = await viewModel.selectProject(first.project.id)
        XCTAssertTrue(didSelectFirst)
        let sourceBranchID = try XCTUnwrap(viewModel.selectedBranchID)
        let createdForkID = await viewModel.forkBranch(
            from: sourceBranchID,
            checkpointID: first.branches[0].headCheckpointID,
            name: "支线"
        )
        let forkID = try XCTUnwrap(createdForkID)
        XCTAssertEqual(viewModel.selectedBranchID, forkID)

        let didSelectSecond = await viewModel.selectProject(second.project.id)
        let didReturnToFirst = await viewModel.selectProject(first.project.id)
        XCTAssertTrue(didSelectSecond)
        XCTAssertTrue(didReturnToFirst)

        XCTAssertEqual(viewModel.selectedProjectID, first.project.id)
        XCTAssertEqual(viewModel.selectedBranchID, forkID)
        XCTAssertEqual(viewModel.branchSnapshot?.branch.id, forkID)
    }

    func testComposerDraftsAreScopedToProjectAndBranch() {
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        let projectID = NovelProjectID()
        let branchID = NovelBranchID()
        let draft = NovelComposerDraft(
            text: "继续写列车抵达雾港。",
            injectionOverrides: NovelInjectionOverrides(
                forceIncludeMaterialIDs: [NovelMaterialID()],
                forceExcludeMaterialIDs: []
            ),
            inputBudgetTokens: 24_000
        )

        viewModel.saveComposerDraft(draft, projectID: projectID, branchID: branchID)

        XCTAssertEqual(
            viewModel.composerDraft(projectID: projectID, branchID: branchID),
            draft
        )
        XCTAssertEqual(
            viewModel.composerDraft(projectID: projectID, branchID: NovelBranchID()),
            .empty
        )
        XCTAssertEqual(
            viewModel.composerDraft(projectID: NovelProjectID(), branchID: branchID),
            .empty
        )
    }

    func testFailedSendRestoresOnlyAnEmptyOwnerDraft() {
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        let owner = NovelComposerDraftOwner(projectID: NovelProjectID(), branchID: NovelBranchID())
        let submitted = NovelComposerDraft(
            text: "刚提交的原文",
            injectionOverrides: .none,
            inputBudgetTokens: 24_000
        )
        viewModel.restoreComposerDraftAfterFailedSend(submitted, owner: owner)
        XCTAssertEqual(
            viewModel.composerDraft(projectID: owner.projectID, branchID: owner.branchID),
            submitted
        )

        let newer = NovelComposerDraft(
            text: "等待时重新输入的内容",
            injectionOverrides: .none,
            inputBudgetTokens: 16_000
        )
        viewModel.saveComposerDraft(newer, projectID: owner.projectID, branchID: owner.branchID)
        viewModel.restoreComposerDraftAfterFailedSend(submitted, owner: owner)
        XCTAssertEqual(
            viewModel.composerDraft(projectID: owner.projectID, branchID: owner.branchID),
            newer
        )
    }

    func testProjectSelectionDoesNotSwitchWhileAnotherProjectOperationIsRunning() async throws {
        let repository = InMemoryNovelProjectRepository()
        let firstDocument = try NovelTestFixtures.document()
        let secondDocument = try NovelTestFixtures.document()
        _ = try await repository.createProject(firstDocument)
        _ = try await repository.createProject(secondDocument)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelectFirstProject = await viewModel.selectProject(firstDocument.project.id)
        XCTAssertTrue(didSelectFirstProject)
        let operationOwnerID = UUID()
        XCTAssertTrue(viewModel.acquireSessionOperation(ownerID: operationOwnerID))

        let didSwitch = await viewModel.selectProject(secondDocument.project.id)

        XCTAssertFalse(didSwitch)
        XCTAssertEqual(viewModel.selectedProjectID, firstDocument.project.id)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, firstDocument.project.id)
        XCTAssertEqual(viewModel.branchSnapshot?.projectID, firstDocument.project.id)
        viewModel.releaseSessionOperation(ownerID: operationOwnerID)
    }

    func testBusyRenameReportsFailureAndDoesNotDismissAsSuccess() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let operationOwnerID = UUID()
        XCTAssertTrue(viewModel.acquireSessionOperation(ownerID: operationOwnerID))

        let renamed = await viewModel.renameProject("不应保存")

        XCTAssertFalse(renamed)
        XCTAssertNotNil(viewModel.errorMessage)
        let stored = try await repository.loadProject(id: document.project.id)
        XCTAssertEqual(stored.document.project.name, document.project.name)
        viewModel.releaseSessionOperation(ownerID: operationOwnerID)
    }

    func testReloadRequirementRejectsTheNextMutationWithAnActionableError() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: creation)
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        await creation.failNextProjectSnapshots(1)

        let renameCommitted = await viewModel.renameProject("已经提交")
        let preferenceSaved = await viewModel.setPolishPreference("不应静默保存")

        XCTAssertTrue(renameCommitted)
        XCTAssertTrue(viewModel.hasReloadRequirement)
        XCTAssertFalse(preferenceSaved)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testBusyBranchOverrideReportsFailureWithoutPersisting() async throws {
        let repository = InMemoryNovelProjectRepository()
        let initial = try NovelTestFixtures.document()
        let document = try NovelReducer.apply(
            NovelTestFixtures.materialAction(document: initial),
            to: initial
        ).document
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let material = try XCTUnwrap(document.materials.first)
        let operationOwnerID = UUID()
        XCTAssertTrue(viewModel.acquireSessionOperation(ownerID: operationOwnerID))

        let saved = await viewModel.setBranchMaterialOverride(
            materialID: material.id,
            change: .inherit
        )

        XCTAssertFalse(saved)
        let stored = try await repository.loadProject(id: document.project.id).document
        XCTAssertEqual(stored.project.configRevision, document.project.configRevision)
        XCTAssertTrue(stored.branches[0].overrideRevisionIDs.isEmpty)
        viewModel.releaseSessionOperation(ownerID: operationOwnerID)
    }

    func testProjectCreationDoesNotSwitchWhileAutomaticSyncIsScheduled() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        viewModel.scheduleAutomaticStateSync(
            projectID: document.project.id,
            branchID: try XCTUnwrap(document.branches.first?.id)
        )

        let createdProjectID = await viewModel.createProject(
            name: "不应创建",
            mode: .blank
        )

        XCTAssertNil(createdProjectID)
        XCTAssertEqual(viewModel.selectedProjectID, document.project.id)
        let projectIDs = try await repository.listProjects().map(\.id)
        XCTAssertEqual(projectIDs, [document.project.id])
        await viewModel.interruptSessionForBackground(deadline: .distantPast)
    }

    func testBranchSelectionDoesNotSwitchWhileAutomaticSyncIsScheduled() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let sourceBranchID = try XCTUnwrap(viewModel.selectedBranchID)
        let createdBranchID = await viewModel.forkBranch(
            from: sourceBranchID,
            checkpointID: document.branches[0].headCheckpointID,
            name: "另一条线"
        )
        let destinationBranchID = try XCTUnwrap(createdBranchID)

        viewModel.scheduleAutomaticStateSync(
            projectID: document.project.id,
            branchID: destinationBranchID
        )
        await viewModel.selectBranch(sourceBranchID)

        XCTAssertEqual(viewModel.selectedBranchID, destinationBranchID)
        XCTAssertEqual(viewModel.branchSnapshot?.branch.id, destinationBranchID)
        XCTAssertNotNil(viewModel.errorMessage)
        await viewModel.interruptSessionForBackground(deadline: .distantPast)
    }

    func testBackgroundWaitIncludesAutomaticSyncBeforeItsDelayedStart() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let branchID = try XCTUnwrap(document.branches.first?.id)
        viewModel.scheduleAutomaticStateSync(
            projectID: document.project.id,
            branchID: branchID
        )
        var waitFinished = false
        let waitTask = Task { @MainActor in
            await viewModel.waitForBackgroundGeneration()
            waitFinished = true
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(waitFinished)

        await waitTask.value
        XCTAssertTrue(waitFinished)
    }

    func testBackgroundWaitKeepsLeaseWhileProjectInventoryIsUnreadable() async throws {
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        await creation.failNextProjectListSnapshots(1)
        let viewModel = NovelCreationViewModel(creation: creation)
        var waitFinished = false
        let waitTask = Task { @MainActor in
            await viewModel.waitForBackgroundGeneration()
            waitFinished = true
        }

        let didObserveFailure = await eventually {
            await creation.projectListSnapshotFailureCount == 1
        }
        XCTAssertTrue(didObserveFailure)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            waitFinished,
            "An unknown project inventory must not be treated as no background generation."
        )

        await waitTask.value
        XCTAssertTrue(waitFinished)
    }

    func testUnknownBackgroundInventoryUsesBoundedBackoffInsteadOfFourHertzScanning() async throws {
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        await creation.failNextProjectListSnapshots(10)
        let viewModel = NovelCreationViewModel(creation: creation)
        let waitTask = Task { @MainActor in
            await viewModel.waitForBackgroundGeneration()
        }

        let didObserveFirstFailure = await eventually {
            await creation.projectListSnapshotFailureCount == 1
        }
        XCTAssertTrue(didObserveFirstFailure)
        try await Task.sleep(for: .milliseconds(700))
        let failureCount = await creation.projectListSnapshotFailureCount

        XCTAssertEqual(failureCount, 1)
        waitTask.cancel()
        await waitTask.value
    }

    func testBackgroundWaitKeepsLeaseWhileAProjectSnapshotIsUnreadable() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        await creation.failNextProjectSnapshots(1)
        let viewModel = NovelCreationViewModel(creation: creation)
        var waitFinished = false
        let waitTask = Task { @MainActor in
            await viewModel.waitForBackgroundGeneration()
            waitFinished = true
        }

        let didObserveFailure = await eventually {
            await creation.projectSnapshotFailureCount == 1
        }
        XCTAssertTrue(didObserveFailure)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            waitFinished,
            "An unreadable project must remain unknown until a later probe succeeds."
        )

        await waitTask.value
        XCTAssertTrue(waitFinished)
    }

    func testBackgroundExpirationUsesCachedInventoryWhenFreshListingFails() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        await creation.failNextProjectListSnapshots(1)
        let viewModel = NovelCreationViewModel(creation: creation)
        viewModel.projects = [NovelProjectSummary(document: document)]

        await viewModel.interruptSessionForBackground(deadline: .distantPast)
        let interruptedProjectIDs = await creation.backgroundInterruptionProjectIDs

        XCTAssertEqual(interruptedProjectIDs, [document.project.id])
    }

    func testForegroundCancelsGatedInventoryBeforeOldCycleCanInterruptLaterProject() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        await creation.gateNextProjectListSnapshot()
        let viewModel = NovelCreationViewModel(creation: creation)
        var expirationHandler: (() -> Void)?
        let coordinator = NovelWorkspaceLifecycleCoordinator(
            now: { .distantFuture },
            beginKeepAlive: { _, onExpire in expirationHandler = onExpire },
            endKeepAlive: { _ in },
            hasProtectedGenerationLease: { false }
        )
        coordinator.enterBackground(
            waitForCompletion: {
                try? await Task.sleep(for: .seconds(30))
            },
            interrupt: { deadline in
                await viewModel.interruptSessionForBackground(deadline: deadline)
            }
        )

        let expire = try XCTUnwrap(expirationHandler)
        expire()
        let didRequest = await eventually {
            await creation.didRequestGatedProjectListSnapshot
        }
        coordinator.enterForeground()
        await creation.releaseProjectListSnapshot()
        XCTAssertTrue(didRequest, "Background expiration must request the gated project inventory.")
        try await Task.sleep(for: .milliseconds(50))
        let interruptedProjectIDs = await creation.backgroundInterruptionProjectIDs

        XCTAssertTrue(
            interruptedProjectIDs.isEmpty,
            "The old background cycle must not capture work discovered after foreground entry."
        )
    }

}
