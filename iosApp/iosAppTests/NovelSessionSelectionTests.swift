import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionSelectionTests: NovelSessionViewModelTestCase {
    func testSelectBranchTerminatesOldDurableRunBeforeRebinding() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("旧分支内容"), .pause])]
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "另一条线"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        XCTAssertNotEqual(destinationBranchID, sourceBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "继续旧分支")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually { harness.session.transientTail?.content == "旧分支内容" }
        XCTAssertTrue(sawPartial)
        let oldRunID = try XCTUnwrap(harness.session.activeRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == oldRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)

        await harness.workspace.selectBranch(destinationBranchID)
        await harness.session.bindToCurrentSelection()

        XCTAssertEqual(harness.session.binding?.branchID, destinationBranchID)
        let final = try await harness.repository.loadProject(id: harness.projectID).document
        let oldRun = try XCTUnwrap(final.activeRuns.first { $0.id == oldRunID })
        XCTAssertEqual(oldRun.status, .interrupted)
        XCTAssertEqual(oldRun.interruptionReason, .routeExit)
    }

    func testSelectBranchPreflightFailureLeavesOldDurableRunRunning() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta("继续生成"), .pause])],
            usesSnapshotGate: true
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "读取失败目标"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "不要误停旧分支")
        XCTAssertTrue(didStart)
        let receivedPartial = await eventually {
            harness.session.transientTail?.content == "继续生成"
        }
        XCTAssertTrue(receivedPartial)
        let oldRunID = try XCTUnwrap(harness.session.activeRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == oldRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)

        await harness.snapshotGate?.failNextBranchSnapshots(1)
        await harness.workspace.selectBranch(destinationBranchID)

        XCTAssertEqual(harness.workspace.selectedBranchID, sourceBranchID)
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.id, sourceBranchID)
        XCTAssertNotNil(harness.workspace.errorMessage)
        XCTAssertFalse(harness.workspace.isPerforming)
        let unchanged = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(unchanged.activeRuns.first(where: { $0.id == oldRunID })?.status, .running)
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertFalse(cancelledRunIDs.contains(oldRunID))

        let interrupted = await harness.session.interruptForRouteExit()
        XCTAssertTrue(interrupted)
    }

    func testPostInterruptRefreshFailureRestoresCoherentSourceSelection() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "加载失败目标"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "先停下再切分支")
        XCTAssertTrue(didStart)
        let oldRunID = try XCTUnwrap(harness.session.activeRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == oldRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)
        harness.session.detachConsumer()
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockInterruptReturn()
        let switchTask = Task { @MainActor in
            await harness.workspace.selectBranch(destinationBranchID)
        }
        let interruptBlocked = await eventually {
            await gate.interruptReturnIsBlocked()
        }
        XCTAssertTrue(interruptBlocked)
        await gate.failNextProjectSnapshots(1)
        await gate.resumeBlockedInterruptReturn()
        await switchTask.value

        XCTAssertEqual(harness.workspace.selectedBranchID, sourceBranchID)
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.id, sourceBranchID)
        XCTAssertNil(harness.workspace.branchSnapshot?.branch.activeRunID)
        XCTAssertEqual(
            harness.workspace.projectSnapshot?.activeRuns.first(where: { $0.id == oldRunID })?.status,
            .interrupted
        )
        XCTAssertNotNil(harness.workspace.errorMessage)
        XCTAssertFalse(harness.workspace.isPerforming)
        await harness.session.bindToCurrentSelection()
        XCTAssertEqual(harness.session.binding?.branchID, sourceBranchID)
        let final = try await harness.repository.loadProject(id: harness.projectID).document
        let oldRun = try XCTUnwrap(final.activeRuns.first { $0.id == oldRunID })
        XCTAssertEqual(oldRun.status, .interrupted)
        XCTAssertEqual(oldRun.interruptionReason, .routeExit)
    }

    func testSelectBranchDoesNotReReadValidatedTargetAfterInterrupt() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "已预检目标"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "预检后切换")
        XCTAssertTrue(didStart)
        let oldRunID = try XCTUnwrap(harness.session.activeRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == oldRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)
        harness.session.detachConsumer()

        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockInterruptReturn()
        let switchTask = Task { @MainActor in
            await harness.workspace.selectBranch(destinationBranchID)
        }
        let interruptBlocked = await eventually {
            await gate.interruptReturnIsBlocked()
        }
        XCTAssertTrue(interruptBlocked)
        await gate.failNextBranchSnapshots(1)
        await gate.resumeBlockedInterruptReturn()
        await switchTask.value

        XCTAssertEqual(harness.workspace.selectedBranchID, destinationBranchID)
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.id, destinationBranchID)
        XCTAssertNil(harness.workspace.errorMessage)
        XCTAssertFalse(harness.workspace.isPerforming)
        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.activeRuns.first(where: { $0.id == oldRunID })?.status, .interrupted)
    }

    func testSelectBranchRevalidatesSelectionOwnershipBeforeInterrupt() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "被并发切换的目标"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan

        let didStart = await harness.session.send(text: "保持旧项目生成")
        XCTAssertTrue(didStart)
        let oldRunID = try XCTUnwrap(harness.session.activeRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == oldRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)
        harness.session.detachConsumer()

        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockNextSnapshot()
        let switchTask = Task { @MainActor in
            await harness.workspace.selectBranch(destinationBranchID)
        }
        let preflightBlocked = await eventually {
            await gate.snapshotIsBlocked()
        }
        XCTAssertTrue(preflightBlocked)
        await gate.blockNextProjectSnapshot()
        let projectSelectionTask = Task { @MainActor in
            await harness.workspace.selectProject(harness.projectID)
        }
        let projectSelectionBlocked = await eventually {
            await gate.projectSnapshotIsBlocked()
        }
        XCTAssertTrue(projectSelectionBlocked)
        await gate.resumeBlockedSnapshot()
        await switchTask.value
        await gate.resumeBlockedProjectSnapshot()
        let didSelectProject = await projectSelectionTask.value

        XCTAssertTrue(didSelectProject)
        XCTAssertEqual(harness.workspace.selectedProjectID, harness.projectID)
        XCTAssertEqual(harness.workspace.selectedBranchID, sourceBranchID)
        XCTAssertFalse(harness.workspace.isPerforming)
        let unchanged = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(unchanged.activeRuns.first(where: { $0.id == oldRunID })?.status, .running)
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertFalse(cancelledRunIDs.contains(oldRunID))

        try? await harness.workspace.interruptSessionRun(NovelCancelRunCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: harness.projectID,
            runID: oldRunID,
            reason: .user
        ))
    }

    func testCommittedForkWithRefreshFailureKeepsCoherentSelectionWithoutOfferingReplay() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let checkpointID = try XCTUnwrap(document.checkpoints.last?.id)
        let harness = try await makeHarness(
            document: document,
            scripts: [],
            usesSnapshotGate: true
        )
        await harness.snapshotGate?.failNextBranchSnapshots(1)

        let forkedBranchID = await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpointID,
            name: "已提交但待重载"
        )

        XCTAssertNil(forkedBranchID)
        XCTAssertEqual(harness.workspace.selectedBranchID, sourceBranchID)
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.id, sourceBranchID)
        XCTAssertNil(harness.workspace.errorMessage)
        XCTAssertNotNil(harness.workspace.reloadNoticeMessage)
        XCTAssertTrue(harness.workspace.requiresReload)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.branches.filter { $0.lifecycle == .active }.count, 2)
        XCTAssertEqual(persisted.appliedOperations.filter { $0.kind == .forkBranch }.count, 1)

        let otherProject = try NovelTestFixtures.document()
        _ = try await harness.repository.createProject(otherProject)
        await harness.workspace.loadProjects(selecting: otherProject.project.id)
        XCTAssertEqual(harness.workspace.selectedProjectID, otherProject.project.id)
        XCTAssertFalse(harness.workspace.requiresReload)
        XCTAssertTrue(harness.workspace.canMutate)
        XCTAssertTrue(harness.workspace.hasReloadRequirement)

        await harness.workspace.retryCommittedMutationReload()
        XCTAssertFalse(harness.workspace.hasReloadRequirement)
        XCTAssertEqual(harness.workspace.selectedProjectID, otherProject.project.id)
        let reloaded = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(reloaded.branches.filter { $0.lifecycle == .active }.count, 2)
        XCTAssertEqual(reloaded.appliedOperations.filter { $0.kind == .forkBranch }.count, 1)
    }

    func testCommittedKeepBothImportWithRefreshFailureDoesNotReportOldSelectionAsSuccess() async throws {
        let source = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            document: source,
            scripts: [],
            usesSnapshotGate: true
        )
        let package = try NovelProjectPackageCodec.encode(source)
        await harness.snapshotGate?.failNextProjectSnapshots(1)

        let result = await harness.workspace.importProject(package.data, choice: .keepBoth)

        guard case .committedNeedsReload(let destinationID) = result else {
            return XCTFail("Expected committedNeedsReload, got \(String(describing: result))")
        }
        XCTAssertNotEqual(destinationID, source.project.id)
        XCTAssertEqual(harness.workspace.selectedProjectID, source.project.id)
        XCTAssertEqual(harness.workspace.projectSnapshot?.project.id, source.project.id)
        XCTAssertNil(harness.workspace.errorMessage)
        XCTAssertTrue(harness.workspace.hasReloadRequirement)
        XCTAssertFalse(harness.workspace.requiresReload)
        let projects = try await harness.repository.listProjects()
        XCTAssertEqual(projects.count, 2)
    }

    func testFreshProjectSelectionKeepsAnotherProjectsScopedReloadRequirement() async throws {
        let repository = InMemoryNovelProjectRepository()
        let first = try NovelTestFixtures.documentWithForkableCheckpoint()
        let second = try NovelTestFixtures.document()
        let harness = try await makeHarness(
            repository: repository,
            document: first,
            scripts: [],
            usesSnapshotGate: true
        )
        _ = try await repository.createProject(second)
        await harness.snapshotGate?.failNextBranchSnapshots(1)
        await harness.workspace.forkBranch(
            from: first.branches[0].id,
            checkpointID: first.branches[0].headCheckpointID,
            name: "待重载分支"
        )
        XCTAssertTrue(harness.workspace.requiresReload)

        await harness.workspace.selectProject(second.project.id)

        XCTAssertEqual(harness.workspace.selectedProjectID, second.project.id)
        XCTAssertEqual(harness.workspace.projectSnapshot?.project.id, second.project.id)
        XCTAssertFalse(harness.workspace.requiresReload)
        XCTAssertNotNil(harness.workspace.reloadNoticeMessage)
        XCTAssertTrue(harness.workspace.hasReloadRequirement)
        XCTAssertTrue(harness.workspace.canMutate)
    }

    func testLoadProjectsKeepsCompleteSelectionWhenBranchRefreshFailsForRetry() async throws {
        let harness = try await makeHarness(
            scripts: [],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.failNextBranchSnapshots(1)

        await harness.workspace.loadProjects(selecting: harness.projectID)

        XCTAssertEqual(harness.workspace.selectedProjectID, harness.projectID)
        XCTAssertEqual(harness.workspace.projectSnapshot?.project.id, harness.projectID)
        XCTAssertEqual(harness.workspace.branchSnapshot?.projectID, harness.projectID)
        XCTAssertNotNil(harness.workspace.errorMessage)

        await harness.workspace.loadProjects(selecting: harness.projectID)
        XCTAssertNil(harness.workspace.errorMessage)
        XCTAssertNotNil(harness.workspace.branchSnapshot)
    }

    func testRouteExitDuringSuspendedStartClosesCrossedDurableRun() async throws {
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        harness.session.mode = .discussPlan
        await repository.blockNextCommit()

        let sendTask = Task { @MainActor in
            await harness.session.send(text: "在落盘前取消")
        }
        let startSuspended = await eventually {
            await repository.commitIsBlocked() && harness.session.isStarting
        }
        XCTAssertTrue(startSuspended)
        XCTAssertTrue(harness.session.canStop)

        let exitTask = Task { @MainActor in
            await harness.session.interruptForRouteExit()
        }
        let cancellationStarted = await eventually {
            harness.session.isPerformingAction
        }
        XCTAssertTrue(cancellationStarted)
        await repository.resumeBlockedCommit()

        let mayExit = await exitTask.value
        let didStart = await sendTask.value
        XCTAssertTrue(mayExit)
        XCTAssertFalse(didStart)
        XCTAssertFalse(harness.session.isStarting)
        XCTAssertFalse(harness.workspace.isPerforming)
        XCTAssertNil(harness.session.transientTail)

        let final = try await repository.loadProject(id: harness.projectID).document
        let run = try XCTUnwrap(final.activeRuns.first)
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.interruptionReason, .routeExit)
        XCTAssertNil(final.branches[0].activeRunID)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBackgroundDuringSuspendedStartClosesCrossedDurableRun() async throws {
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        harness.session.mode = .discussPlan
        await repository.blockNextCommit()

        let sendTask = Task { @MainActor in
            await harness.session.send(text: "切到后台前仍在落盘")
        }
        let startSuspended = await eventually {
            await repository.commitIsBlocked() && harness.session.isStarting
        }
        XCTAssertTrue(startSuspended)

        let backgroundTask = Task { @MainActor in
            await harness.session.interruptForBackground(
                deadline: Date().addingTimeInterval(2)
            )
        }
        let cancellationStarted = await eventually {
            harness.session.isPerformingAction
        }
        XCTAssertTrue(cancellationStarted)
        await repository.resumeBlockedCommit()
        await backgroundTask.value
        let didStart = await sendTask.value
        XCTAssertFalse(didStart)

        let final = try await repository.loadProject(id: harness.projectID).document
        let run = try XCTUnwrap(final.activeRuns.first)
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.interruptionReason, .background)
        XCTAssertNil(final.branches[0].activeRunID)
        XCTAssertNil(harness.session.transientTail)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBackgroundBeforeActorStartCannotLeaveAHiddenRun() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.pause])],
            usesAttachGate: true
        )
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.blockNextStart()
        let sendTask = Task { @MainActor in
            await harness.session.send(text: "在 actor 接收前切到后台")
        }
        let startBlocked = await eventually {
            await gate.startIsBlocked() && harness.session.isStarting
        }
        XCTAssertTrue(startBlocked)

        await harness.session.interruptForBackground(
            deadline: Date().addingTimeInterval(2)
        )
        await gate.resumeBlockedStart()
        let didStart = await sendTask.value

        XCTAssertFalse(didStart)
        XCTAssertFalse(harness.workspace.isPerforming)
        XCTAssertNil(harness.session.transientTail)
        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertTrue(final.activeRuns.isEmpty)
        XCTAssertNil(final.branches[0].activeRunID)
        XCTAssertTrue(final.sessions[0].messages.isEmpty)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

}
