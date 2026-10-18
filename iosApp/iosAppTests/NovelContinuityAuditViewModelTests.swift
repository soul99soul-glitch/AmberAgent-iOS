import XCTest
@testable import iosApp

/// 报告归当前选中的项目/分支所有。换项目、fork、删分支等路径不走 `selectProject`,
/// 靠「每个变更点手动清一次」必然漏,所以读取侧必须自己过滤。
@MainActor
final class NovelContinuityAuditViewModelTests: XCTestCase {
    func testCancellationWinsWhenContinuityRuntimeReturnsAfterIgnoringIt() async throws {
        let repository = InMemoryNovelProjectRepository()
        let fixture = try documentWithOneChapter()
        _ = try await repository.createProject(fixture)
        let runtime = CancellationIgnoringContinuityCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: runtime)
        let didSelect = await viewModel.selectProject(fixture.project.id)
        XCTAssertTrue(didSelect)
        let branchID = try XCTUnwrap(viewModel.selectedBranchID)

        viewModel.startContinuityAuditPlanning()
        let planningStarted = await eventually { await runtime.hasStartedPlanning }
        XCTAssertTrue(planningStarted)
        viewModel.cancelContinuityAudit()
        await runtime.resumePlanning(NovelContinuityAuditPlan(
            projectID: fixture.project.id,
            branchID: branchID,
            chapterCount: 1,
            chunkCount: 1,
            totalCharacterCount: 20
        ))
        let planningStopped = await eventually { !viewModel.isContinuityOperationRunning }
        XCTAssertTrue(planningStopped)
        XCTAssertNil(viewModel.continuityAuditPlan)

        viewModel.startContinuityAudit()
        let auditStarted = await eventually { await runtime.hasStartedAudit }
        XCTAssertTrue(auditStarted)
        let continuityLeaseID = BackgroundGenerationKeepAlive.shared.activeLeaseIds.first(where: {
            $0.hasPrefix("novel-continuity-")
        })
        XCTAssertNotNil(continuityLeaseID)
        viewModel.cancelContinuityAudit()
        await runtime.resumeAudit(NovelContinuityAuditReport(
            projectID: fixture.project.id,
            branchID: branchID,
            auditedChapterSelections: viewModel.branchSnapshot?.chapterSelections ?? [],
            promptVersion: "test",
            scannedChapterCount: 1,
            chunkCount: 1,
            failedChunkCount: 0,
            issues: [],
            droppedIssueCount: 0,
            createdAt: Date()
        ))
        let auditStopped = await eventually { !viewModel.isContinuityOperationRunning }
        XCTAssertTrue(auditStopped)
        XCTAssertNil(viewModel.continuityAudit)
        if let continuityLeaseID {
            XCTAssertFalse(BackgroundGenerationKeepAlive.shared.holdsLease(continuityLeaseID))
        }
    }

    func testContinuityFailureIsHiddenAfterSelectionMovesToAnotherProject() async throws {
        let repository = InMemoryNovelProjectRepository()
        let first = try documentWithOneChapter()
        let second = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(first)
        _ = try await repository.createProject(second)
        let runtime = CancellationIgnoringContinuityCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: runtime)
        let didSelectFirst = await viewModel.selectProject(first.project.id)
        XCTAssertTrue(didSelectFirst)

        viewModel.startContinuityAuditPlanning()
        let planningStarted = await eventually { await runtime.hasStartedPlanning }
        XCTAssertTrue(planningStarted)
        await runtime.failPlanning()
        let failurePublished = await eventually { viewModel.continuityAuditFailure != nil }
        XCTAssertTrue(failurePublished)

        let didSelectSecond = await viewModel.selectProject(second.project.id)
        XCTAssertTrue(didSelectSecond)
        XCTAssertNil(viewModel.continuityAuditFailure)
    }

    func testPlanningTaskRemainsVisibleAndCanBeStoppedAfterItsViewDisappears() async throws {
        let repository = InMemoryNovelProjectRepository()
        let fixture = try documentWithOneChapter()
        _ = try await repository.createProject(fixture)
        let blocking = BlockingContinuityPlanningCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: blocking)
        let didSelect = await viewModel.selectProject(fixture.project.id)
        XCTAssertTrue(didSelect)

        viewModel.startContinuityAuditPlanning()
        let started = await eventually {
            await blocking.hasStartedPlanning &&
                viewModel.isPlanningContinuity &&
                viewModel.isContinuityOperationRunning &&
                viewModel.isPerforming
        }
        XCTAssertTrue(started)

        viewModel.cancelContinuityAudit()

        let stopped = await eventually {
            !viewModel.isContinuityOperationRunning && !viewModel.isPerforming
        }
        XCTAssertTrue(stopped)
        XCTAssertNil(viewModel.continuityAuditPlan)
        XCTAssertNil(viewModel.continuityAuditFailure)
    }

    func testReportIsHiddenAfterTheSelectionMovesToAnotherProject() async throws {
        let repository = InMemoryNovelProjectRepository()
        let fixture = try documentWithOneChapter()
        _ = try await repository.createProject(fixture)
        let other = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(other)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "audit-provider",
                ownerProviderID: "audit-owner",
                modelID: "audit-model-id",
                wireModelID: "audit-model-wire",
                displayName: "Audit Model",
                contextWindowTokens: 128_000
            ),
            scripts: [NovelModelScript(steps: [
                .delta("{\"schemaVersion\": 1, \"consistent\": true, \"issues\": []}"),
                .complete,
            ])]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )

        let didSelectAudited = await viewModel.selectProject(fixture.project.id)
        XCTAssertTrue(didSelectAudited)
        await viewModel.auditContinuity()
        XCTAssertNotNil(viewModel.continuityAudit)

        let didSelectOther = await viewModel.selectProject(other.project.id)
        XCTAssertTrue(didSelectOther)
        XCTAssertNil(
            viewModel.continuityAudit,
            "换项目之后不能再显示上一个项目的扫描结果"
        )
    }

    private func documentWithOneChapter() throws -> NovelProjectDocumentV1 {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let branch = document.branches[0]
        let operationID = document.appliedOperations[0].operationID
        let chapterID = NovelChapterID()
        let versionID = NovelChapterVersionID()
        let createdAt = Date(timeIntervalSince1970: 1_700_500_000)
        document.chapters.append(NovelChapterRecord(id: chapterID, createdAt: createdAt))
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: chapterID,
            kind: .collected,
            title: "渡口",
            content: "林岸在渡口第一次见到苏未晚，两个人交换了姓名。",
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: createdAt,
            operationID: operationID
        ))
        let selection = NovelChapterSelection(chapterID: chapterID, versionID: versionID)
        let checkpointIndex = try XCTUnwrap(document.checkpoints.firstIndex {
            $0.id == branch.headCheckpointID
        })
        let checkpoint = document.checkpoints[checkpointIndex]
        document.checkpoints[checkpointIndex] = NovelBranchCheckpointRecord(
            id: checkpoint.id,
            kind: checkpoint.kind,
            createdOnBranchID: checkpoint.createdOnBranchID,
            parentCheckpointID: checkpoint.parentCheckpointID,
            chapterSelections: [selection],
            stateSnapshotID: checkpoint.stateSnapshotID,
            sessionCursor: checkpoint.sessionCursor,
            branchOverrideRevisionIDs: checkpoint.branchOverrideRevisionIDs,
            sourceCandidateID: checkpoint.sourceCandidateID,
            baseHeadRevision: checkpoint.baseHeadRevision,
            operationID: checkpoint.operationID,
            createdAt: checkpoint.createdAt
        )
        document.branches[0].workingChapterSelections = [selection]
        try NovelDocumentValidator.validate(document)
        return document
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor BlockingContinuityPlanningCreation: NovelCreation {
    private let base: any NovelCreation
    private(set) var hasStartedPlanning = false

    init(base: any NovelCreation) {
        self.base = base
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        try await base.snapshot(scope)
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

    func planContinuityAudit(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditPlan {
        hasStartedPlanning = true
        try await Task.sleep(for: .seconds(60))
        return try await base.planContinuityAudit(projectID: projectID, branchID: branchID)
    }
}

private actor CancellationIgnoringContinuityCreation: NovelCreation {
    private let base: any NovelCreation
    private var planningContinuation: CheckedContinuation<NovelContinuityAuditPlan, Error>?
    private var auditContinuation: CheckedContinuation<NovelContinuityAuditReport, Error>?
    private(set) var hasStartedPlanning = false
    private(set) var hasStartedAudit = false

    init(base: any NovelCreation) {
        self.base = base
    }

    func snapshot(_ scope: NovelSnapshotScope) async throws -> NovelSnapshot {
        try await base.snapshot(scope)
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

    func planContinuityAudit(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditPlan {
        hasStartedPlanning = true
        return try await withCheckedThrowingContinuation { continuation in
            planningContinuation = continuation
        }
    }

    func auditContinuity(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelContinuityAuditReport {
        hasStartedAudit = true
        return try await withCheckedThrowingContinuation { continuation in
            auditContinuation = continuation
        }
    }

    func resumePlanning(_ plan: NovelContinuityAuditPlan) {
        planningContinuation?.resume(returning: plan)
        planningContinuation = nil
    }

    func failPlanning() {
        planningContinuation?.resume(
            throwing: NovelError.repositoryFailure("Injected continuity planning failure.")
        )
        planningContinuation = nil
    }

    func resumeAudit(_ report: NovelContinuityAuditReport) {
        auditContinuation?.resume(returning: report)
        auditContinuation = nil
    }
}
