import XCTest
@testable import iosApp

@MainActor
final class NovelCreationProjectPresentationTests: XCTestCase {
    func testCompositionCreatesAFileBackedViewModelAndReloadsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelCompositionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "NovelCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeNovelTestSettings(userDefaults: defaults)

        let first = try NovelCreationComposition.makeViewModel(
            sharedSettings: settings,
            rootDirectory: root
        )
        let createdProjectID = await first.createProject(name: "测试路由", mode: .blank)
        let projectID = try XCTUnwrap(createdProjectID)

        let restarted = try NovelCreationComposition.makeViewModel(
            sharedSettings: settings,
            rootDirectory: root
        )
        await restarted.loadProjects(selecting: projectID)

        XCTAssertEqual(restarted.projectSnapshot?.project.name, "测试路由")
        XCTAssertEqual(restarted.selectedBranchID, restarted.projectSnapshot?.project.mainBranchID)
        XCTAssertNil(restarted.errorMessage)
    }

    func testNovelContextRingUsesModelWindowNotInjectionBudget() {
        let snapshot = NovelSessionContextRing.snapshot(
            messageCount: 10,
            modelId: "muse-spark-1.2-contributor",
            modelWindowTokens: 1_000_000,
            estimatedInjectionTokens: 16_000,
            supportsReasoning: false
        )
        XCTAssertEqual(snapshot.occupancyText, "16K / 1M")
        XCTAssertEqual(snapshot.resolvedWindowTokens, 1_000_000)
        XCTAssertEqual(snapshot.currentContextTokens, 16_000)
        XCTAssertEqual(snapshot.contextFillFraction, 0.016, accuracy: 0.0001)
    }

    func testNovelContextRingFallsBackToRegistryWhenModelOmitsWindow() {
        let snapshot = NovelSessionContextRing.snapshot(
            messageCount: 1,
            modelId: "claude-sonnet-4-5",
            modelWindowTokens: nil,
            estimatedInjectionTokens: 16_000,
            supportsReasoning: false
        )
        XCTAssertEqual(snapshot.occupancyText, "16K / 1M")
        XCTAssertEqual(snapshot.resolvedWindowTokens, 1_000_000)
    }

    func testUnavailableModelFailurePointsToTheLiveSettingsEntry() {
        XCTAssertEqual(
            NovelPresentation.failureMessage(NovelFailure(
                code: "fixed_model_missing",
                message: "The configured model no longer exists.",
                isRetryable: false
            )),
            "项目绑定的模型已失效（服务商或模型 ID 已变）。请在右上角「项目模型覆盖」重新选择，或改回跟随全局。"
        )
    }

    func testCheckpointLineageIsHeadToRootAndStopsAtInitialCheckpoint() throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let snapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: document,
            access: .readWrite
        ))

        let lineage = NovelPresentation.checkpointLineage(
            for: document.branches[0],
            in: snapshot
        )

        let parentCheckpointID = try XCTUnwrap(lineage.first?.parentCheckpointID)
        XCTAssertEqual(lineage.map(\.id), [
            document.branches[0].headCheckpointID,
            parentCheckpointID,
        ])
        XCTAssertEqual(lineage.last?.kind, .initial)
        let forkable = NovelPresentation.forkableCheckpoints(
            for: document.branches[0],
            in: snapshot
        )
        XCTAssertEqual(forkable.map(\.id), [document.branches[0].headCheckpointID])
        XCTAssertFalse(forkable.contains(where: { $0.kind == .initial }))
    }

    func testActionCheckpointLineageStopsAtForkBoundaryAndIncludesLocalHistory() throws {
        let source = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranch = source.branches[0]
        let childID = NovelBranchID()
        let command = NovelBranchTestFixtures.forkCommand(
            document: source,
            sourceBranchID: sourceBranch.id,
            checkpointID: sourceBranch.headCheckpointID,
            branchID: childID,
            name: "支线"
        )
        let forked = try NovelReducer.apply(.forkBranch(command), to: source).document
        let child = try XCTUnwrap(forked.branches.first(where: { $0.id == childID }))
        let freshSnapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: forked,
            access: .readWrite
        ))

        XCTAssertEqual(
            NovelPresentation.actionCheckpointLineage(for: child, in: freshSnapshot).map(\.id),
            [sourceBranch.headCheckpointID]
        )
        XCTAssertEqual(
            NovelPresentation.forkableCheckpoints(for: child, in: freshSnapshot).map(\.id),
            [sourceBranch.headCheckpointID]
        )

        var advanced = forked
        let localCheckpoint = NovelBranchCheckpointRecord(
            id: NovelCheckpointID(),
            kind: .manualSync,
            createdOnBranchID: childID,
            parentCheckpointID: child.headCheckpointID,
            chapterSelections: child.workingChapterSelections,
            stateSnapshotID: child.currentStateSnapshotID,
            sessionCursor: .empty,
            branchOverrideRevisionIDs: child.overrideRevisionIDs,
            sourceCandidateID: nil,
            baseHeadRevision: child.headRevision,
            operationID: NovelOperationID(),
            createdAt: Date()
        )
        advanced.checkpoints.append(localCheckpoint)
        let childIndex = try XCTUnwrap(advanced.branches.firstIndex(where: { $0.id == childID }))
        advanced.branches[childIndex].headCheckpointID = localCheckpoint.id
        advanced.branches[childIndex].headRevision += 1
        let advancedSnapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: advanced,
            access: .readWrite
        ))

        XCTAssertEqual(
            NovelPresentation.actionCheckpointLineage(
                for: advanced.branches[childIndex],
                in: advancedSnapshot
            ).map(\.id),
            [localCheckpoint.id, sourceBranch.headCheckpointID]
        )
    }

    func testCheckpointChapterOrdinalUsesTheBranchSelectionOrder() {
        let branchID = NovelBranchID()
        let projectChapterIDs = [NovelChapterID(), NovelChapterID(), NovelChapterID()]
        let branchChapterIDs = [projectChapterIDs[0], projectChapterIDs[2]]
        let parent = NovelBranchCheckpointRecord(
            id: NovelCheckpointID(),
            kind: .collection,
            createdOnBranchID: branchID,
            parentCheckpointID: nil,
            chapterSelections: branchChapterIDs.map {
                NovelChapterSelection(chapterID: $0, versionID: NovelChapterVersionID())
            },
            stateSnapshotID: NovelStateSnapshotID(),
            sessionCursor: .empty,
            branchOverrideRevisionIDs: [],
            sourceCandidateID: nil,
            baseHeadRevision: 0,
            operationID: NovelOperationID(),
            createdAt: Date()
        )
        var selections = parent.chapterSelections
        selections[1] = NovelChapterSelection(
            chapterID: branchChapterIDs[1],
            versionID: NovelChapterVersionID()
        )
        let child = NovelBranchCheckpointRecord(
            id: NovelCheckpointID(),
            kind: .collection,
            createdOnBranchID: branchID,
            parentCheckpointID: parent.id,
            chapterSelections: selections,
            stateSnapshotID: NovelStateSnapshotID(),
            sessionCursor: .empty,
            branchOverrideRevisionIDs: [],
            sourceCandidateID: nil,
            baseHeadRevision: 1,
            operationID: NovelOperationID(),
            createdAt: Date()
        )

        XCTAssertEqual(
            NovelCheckpointLabel.chapterOrdinal(
                for: child,
                checkpoints: [parent, child]
            ),
            2
        )
    }

    func testDirectChapterRestoreRequiresTheSameFactCompatibilityLineage() {
        let chapterID = NovelChapterID()
        let compatibilityID = UUID()
        let current = NovelChapterVersionRecord(
            id: NovelChapterVersionID(),
            chapterID: chapterID,
            kind: .polish,
            title: "Current",
            content: "Current",
            factCompatibilityID: compatibilityID,
            sourceCandidateID: nil,
            createdAt: Date(),
            operationID: NovelOperationID()
        )
        let compatible = NovelChapterVersionRecord(
            id: NovelChapterVersionID(),
            chapterID: chapterID,
            kind: .restore,
            title: "Compatible",
            content: "Compatible",
            factCompatibilityID: compatibilityID,
            sourceCandidateID: nil,
            createdAt: Date(),
            operationID: NovelOperationID()
        )
        let incompatible = NovelChapterVersionRecord(
            id: NovelChapterVersionID(),
            chapterID: chapterID,
            kind: .manualEdit,
            title: "Incompatible",
            content: "Incompatible",
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: Date(),
            operationID: NovelOperationID()
        )

        XCTAssertTrue(NovelPresentation.canDirectlyRestore(compatible, from: current))
        XCTAssertFalse(NovelPresentation.canDirectlyRestore(incompatible, from: current))
        XCTAssertFalse(NovelPresentation.canDirectlyRestore(current, from: current))
    }

    func testDegradedSnapshotDisablesViewModelMutations() throws {
        let document = try NovelTestFixtures.document()
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )
        viewModel.projectSnapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: document,
            access: .degradedPrevious(primaryFailure: "corrupt primary")
        ))

        XCTAssertFalse(viewModel.canMutate)
    }

    func testRefreshCurrentSelectionPatchesProjectSummaryWithoutReadingProjectList() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        let otherDocument = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        _ = try await repository.createProject(otherDocument)
        let base = DefaultNovelCreation(repository: repository)
        let creation = ProjectListReadGuardNovelCreation(
            base: base,
            rejectsProjectListReads: true
        )
        let viewModel = NovelCreationViewModel(creation: creation)
        viewModel.projects = [
            NovelProjectSummary(document: document),
            NovelProjectSummary(document: otherDocument)
        ].sorted(by: NovelProjectSummary.listOrder)
        viewModel.selectedProjectID = document.project.id
        viewModel.selectedBranchID = document.project.mainBranchID

        _ = try await base.perform(NovelTestFixtures.renameAction(
            document: document,
            name: "已更新的项目卡片"
        ))

        let refreshed = try await viewModel.refreshCurrentSelection(
            projectID: document.project.id,
            refreshProjectList: false
        )

        XCTAssertTrue(refreshed)
        let selectedSummary = try XCTUnwrap(viewModel.projects.first {
            $0.id == document.project.id
        })
        let refreshedProject = try XCTUnwrap(viewModel.projectSnapshot)
        XCTAssertEqual(selectedSummary.name, "已更新的项目卡片")
        XCTAssertEqual(selectedSummary.revision, refreshedProject.project.revision)
        XCTAssertEqual(selectedSummary.updatedAt, refreshedProject.project.updatedAt)
        XCTAssertEqual(
            selectedSummary.hasRunningRun,
            refreshedProject.activeRuns.contains(where: { $0.status == .running })
        )
        XCTAssertEqual(viewModel.projects, viewModel.projects.sorted(by: NovelProjectSummary.listOrder))
    }

    func testLateProjectSnapshotCannotReplaceNewerSelection() async throws {
        let repository = InMemoryNovelProjectRepository()
        let firstDocument = try NovelTestFixtures.document()
        let secondDocument = try NovelTestFixtures.document()
        _ = try await repository.createProject(firstDocument)
        _ = try await repository.createProject(secondDocument)
        let base = DefaultNovelCreation(repository: repository)
        let delayed = DelayedProjectSnapshotNovelCreation(
            base: base,
            delayedProjectID: firstDocument.project.id
        )
        let viewModel = NovelCreationViewModel(creation: delayed)

        let firstSelection = Task { @MainActor in
            _ = await viewModel.selectProject(firstDocument.project.id)
        }
        try await Task.sleep(for: .milliseconds(30))
        await viewModel.selectProject(secondDocument.project.id)
        await firstSelection.value

        XCTAssertEqual(viewModel.selectedProjectID, secondDocument.project.id)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, secondDocument.project.id)
        XCTAssertEqual(viewModel.branchSnapshot?.projectID, secondDocument.project.id)
    }
}

private actor ProjectListReadGuardNovelCreation: NovelCreation {
    let base: any NovelCreation
    let rejectsProjectListReads: Bool

    init(
        base: any NovelCreation,
        rejectsProjectListReads: Bool = false
    ) {
        self.base = base
        self.rejectsProjectListReads = rejectsProjectListReads
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if case .projects = scope, rejectsProjectListReads {
            throw NovelError.invalidInput("Unexpected project list refresh.")
        }
        return try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        await base.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: runID
        )
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        await base.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        try await base.retryPendingTerminal(runID: runID)
    }
}

private actor DelayedProjectSnapshotNovelCreation: NovelCreation {
    let base: any NovelCreation
    let delayedProjectID: NovelProjectID

    init(base: any NovelCreation, delayedProjectID: NovelProjectID) {
        self.base = base
        self.delayedProjectID = delayedProjectID
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        if case .project(let projectID) = scope, projectID == delayedProjectID {
            try await Task.sleep(for: .milliseconds(150))
        }
        return try await base.snapshot(scope)
    }

    func perform(_ action: NovelAction) async throws -> NovelOutcome {
        try await base.perform(action)
    }

    func start(_ request: NovelRunRequest) async throws -> NovelRun {
        try await base.start(request)
    }

    func interruptForBackground(
        projectID: NovelProjectID,
        deadline: Date,
        runID: NovelRunID?
    ) async {
        await base.interruptForBackground(
            projectID: projectID,
            deadline: deadline,
            runID: runID
        )
    }

    func cancelInFlightBackgroundMutations(projectID: NovelProjectID) async {
        await base.cancelInFlightBackgroundMutations(projectID: projectID)
    }

    func retryPendingTerminal(runID: NovelRunID) async throws {
        try await base.retryPendingTerminal(runID: runID)
    }
}
