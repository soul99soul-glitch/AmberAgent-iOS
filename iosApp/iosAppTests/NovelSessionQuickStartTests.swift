import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionQuickStartTests: NovelSessionViewModelTestCase {
    func testPersistenceBlockedTailRetriesTheSameRun() async throws {
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            scripts: [NovelModelScript(steps: [.delta("等待落盘"), .pause, .complete])]
        )
        harness.session.mode = .discussPlan
        let didStart = await harness.session.send(text: "给我一个建议")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually { harness.session.transientTail?.content == "等待落盘" }
        XCTAssertTrue(sawPartial)
        let runID = try XCTUnwrap(harness.session.activeRunID)

        await repository.failNextCommits(3)
        await harness.adapter.resume(runID: runID)
        let sawBlockedTerminal = await eventually { harness.session.canRetryPendingTerminal }
        XCTAssertTrue(sawBlockedTerminal)
        XCTAssertFalse(harness.session.canSend)
        let blockedTail = harness.session.transientTail
        let secondStart = await harness.session.send(text: "不应覆盖待保存回复")
        XCTAssertFalse(secondStart)
        XCTAssertEqual(harness.session.transientTail, blockedTail)
        let blockedError = harness.session.operationErrorMessage
        await harness.session.interruptForRouteExit()
        XCTAssertEqual(harness.session.operationErrorMessage, blockedError)
        guard case .persistenceBlocked = harness.session.transientTail?.phase else {
            return XCTFail("Route exit must preserve the persistence-blocked terminal claim.")
        }
        await harness.session.retryPendingTerminal()
        let didFinish = await eventually { !harness.session.isRunning }
        XCTAssertTrue(didFinish)
        XCTAssertTrue(harness.session.canSend)

        let final = try await repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.activeRuns.first { $0.id == runID }?.status, .completed)
        XCTAssertEqual(final.sessions[0].messages.last?.content, "等待落盘")
    }

    /// 真机回归：快速开始失败后重试曾退回默认文案，丢失用户填写的调整方向。
    func testQuickStartTerminalBubbleRetriesOriginalGuidanceThroughWorkspaceFlow() async throws {
        let guidance = "保留北宋背景，改成双主角。\n人物关系先于世界观展开。"
        let originalUserText = """
        请生成一组可确认的世界观、人物、总剧情大纲和写作要求建议。

        用户对上一版建议不满意，要求按以下方向调整重新生成：
        保留北宋背景，改成双主角。
        人物关系先于世界观展开。
        """
        let retryableFailure = NovelModelFailure(
            code: "quick_start_failed",
            message: "快速开始暂时失败",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [
                NovelModelScript(steps: [.fail(retryableFailure)]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
            ]
        )

        await harness.workspace.startQuickStartSuggestions(guidance: guidance)
        let firstFailed = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed
        }
        XCTAssertTrue(firstFailed)
        let failedRunID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)
        await harness.session.bindToCurrentSelection()

        let retried = await harness.session.retryGeneration(runID: failedRunID)
        XCTAssertTrue(retried)
        let completed = await eventually {
            harness.workspace.projectSnapshot?.settingProposals.count == 4 &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed
        }
        XCTAssertTrue(completed)
        XCTAssertNotEqual(harness.workspace.projectSnapshot?.activeRuns.last?.id, failedRunID)
        let requests = await harness.adapter.requests
        XCTAssertEqual(
            requests.map { $0.messages.last(where: { $0.role == .user })?.content },
            [originalUserText, originalUserText]
        )
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            persisted.sessions[0].messages.filter { $0.role == .user }.map(\.content),
            [originalUserText, originalUserText]
        )
    }

    func testQuickStartRetryReportsAcceptedWhenRunCompletesDuringBinding() async throws {
        let failure = NovelModelFailure(
            code: "quick_start_failed", message: "快速开始暂时失败", isRetryable: true
        )
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
            ],
            usesSnapshotGate: true
        )
        let startedID = await harness.workspace.startQuickStartSuggestions()
        let failedRunID = try XCTUnwrap(startedID)
        let failed = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.workspace.quickStartStartingRun == nil
        }
        XCTAssertTrue(failed)
        await harness.session.bindToCurrentSelection()

        let busyOwner = UUID()
        XCTAssertTrue(harness.workspace.acquireSessionOperation(ownerID: busyOwner))
        let rejected = await harness.session.retryGeneration(runID: failedRunID)
        XCTAssertFalse(rejected)
        XCTAssertEqual(harness.workspace.projectSnapshot?.activeRuns.count, 1)
        harness.workspace.releaseSessionOperation(ownerID: busyOwner)

        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.blockNextBindingRestore()
        let retryTask = Task { @MainActor in
            await harness.session.retryGeneration(runID: failedRunID)
        }
        let bindingBlocked = await eventually { await gate.bindingRestoreIsBlocked() }
        XCTAssertTrue(bindingBlocked)
        let completedBeforeBindingReturned = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.workspace.projectSnapshot?.activeRuns.last?.id != failedRunID &&
                harness.workspace.projectSnapshot?.settingProposals.count == 4 &&
                harness.workspace.quickStartStatus == .idle
        }
        XCTAssertTrue(completedBeforeBindingReturned)
        await gate.resumeBlockedBindingRestore()
        let accepted = await retryTask.value
        XCTAssertTrue(accepted, harness.session.operationErrorMessage ?? "Completed retry was reported as rejected.")
        XCTAssertFalse(harness.session.isRunning)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.activeRuns.count, 2)
        XCTAssertEqual(persisted.activeRuns.last?.status, .completed)
        let userInputs = persisted.sessions[0].messages.filter { $0.role == .user }
        XCTAssertEqual(userInputs.count, 2)
        XCTAssertEqual(userInputs.first?.content, userInputs.last?.content)
    }

    func testInitialPausedQuickStartRefreshesAndAttachesSession() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [.pause])]
        )

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        await harness.session.bindToCurrentSelection()

        XCTAssertEqual(harness.session.activeRunID, runID)
        XCTAssertTrue(harness.session.canStop)
        XCTAssertNotNil(harness.session.transientTail)
        await harness.session.stop()
    }

    func testQuickStartPlaceholderHandsOffToDurableStreamingConsumer() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [
                .pause,
                .delta(quickStartSuggestionsJSON),
                .pause,
                .complete,
            ])]
        )

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        await harness.session.bindToCurrentSelection()
        XCTAssertEqual(harness.session.activeRunID, runID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true && harness.workspace.quickStartStartingRun == nil
        }
        XCTAssertTrue(becameDurable, "Quick Start must cross the durable start boundary before replaying deltas.")
        harness.session.detachConsumer()
        let firstBind = Task { @MainActor in
            await harness.session.bindToCurrentSelection()
        }
        let secondBind = Task { @MainActor in
            await harness.session.bindToCurrentSelection()
        }
        await firstBind.value
        await secondBind.value
        await harness.adapter.resume(runID: runID)
        let receivedDelta = await eventually {
            harness.session.transientTail?.phase == .streaming
        }
        XCTAssertTrue(receivedDelta)
        XCTAssertTrue(harness.session.transientTail?.content.contains("# 创作建议") == true)
        XCTAssertFalse(harness.session.transientTail?.content.contains("schemaVersion") == true)
        await harness.session.stop()
    }

    func testQuickStartDeltasPublishUserFacingStreamingPreview() async throws {
        let hiddenDeltas = quickStartSuggestionsJSON
            .components(separatedBy: "\n")
            .map { NovelModelScriptStep.delta($0 + "\n") }
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [.pause] + hiddenDeltas + [.pause, .complete])]
        )

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        await harness.session.bindToCurrentSelection()
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true && harness.workspace.quickStartStartingRun == nil
        }
        XCTAssertTrue(becameDurable)
        await harness.session.bindToCurrentSelection()

        await harness.adapter.resume(runID: runID)
        let receivedVisibleOutput = await eventually {
            harness.session.transientTail?.phase == .streaming &&
                harness.session.transientTail?.content.contains("# 创作建议") == true
        }
        XCTAssertTrue(receivedVisibleOutput)
        let receivedCharacterSection = await eventually {
            harness.session.transientTail?.content.contains("## 人物") == true
        }
        let content = try XCTUnwrap(harness.session.transientTail?.content)
        XCTAssertTrue(receivedCharacterSection, "streaming preview: \(content)")
        XCTAssertTrue(content.contains("## 世界观"))
        XCTAssertFalse(content.contains("schemaVersion"))
        XCTAssertFalse(content.contains("aliases"))
        await harness.session.stop()
    }

    func testPreBindRouteExitCancelsSuspendedQuickStart() async throws {
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let unboundSession = NovelSessionViewModel(workspace: harness.workspace)
        await repository.blockNextCommit()
        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        let commitBlocked = await eventually { await repository.commitIsBlocked() }
        XCTAssertTrue(commitBlocked)

        let exitTask = Task { @MainActor in
            await unboundSession.interruptForRouteExit()
        }
        let cancellationStarted = await eventually { unboundSession.isPerformingAction }
        XCTAssertTrue(cancellationStarted)
        await repository.resumeBlockedCommit()

        let mayExit = await exitTask.value
        XCTAssertTrue(mayExit)
        let final = try await repository.loadProject(id: harness.projectID).document
        let run = try XCTUnwrap(final.activeRuns.first { $0.id == runID })
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.interruptionReason, .routeExit)
        XCTAssertNil(final.branches[0].activeRunID)
        XCTAssertNil(harness.workspace.quickStartStartingRun)
    }

    func testQuickStartPreDurableFailureClearsSessionPlaceholder() async throws {
        let failure = NovelModelFailure(
            code: "resolve_failed",
            message: "模型暂时不可用",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [],
            resolutionFailure: failure
        )

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        await harness.session.bindToCurrentSelection()
        XCTAssertEqual(harness.session.activeRunID, runID)
        let failed = await eventually {
            if case .failed = harness.workspace.quickStartStatus { return true }
            return false
        }
        XCTAssertTrue(failed)
        await harness.session.bindToCurrentSelection()
        XCTAssertNil(harness.session.transientTail)
        XCTAssertFalse(harness.session.isRunning)
        XCTAssertTrue(harness.workspace.projectSnapshot?.activeRuns.isEmpty == true)
    }

    func testQuickStartReloadAfterStartRefreshFailureCanAttachPausedRun() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.failNextSnapshots(2)

        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        let refreshFailed = await eventually {
            if case .refreshFailed = harness.workspace.quickStartStatus { return true }
            return false
        }
        XCTAssertTrue(refreshFailed)
        XCTAssertFalse(harness.workspace.projectSnapshot?.activeRuns.contains(where: {
            $0.id == runID && $0.status == .running
        }) == true)

        await harness.workspace.reloadQuickStartProject()
        await harness.session.bindToCurrentSelection()
        XCTAssertEqual(harness.session.activeRunID, runID)
        XCTAssertTrue(harness.session.canStop)
        XCTAssertNotNil(harness.session.transientTail)
        await harness.session.stop()
    }

    func testQuickStartStopReleasesBusyStateWhenTerminalRefreshFails() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [.pause])],
            usesSnapshotGate: true
        )
        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)
        await harness.session.bindToCurrentSelection()
        let gate = try XCTUnwrap(harness.snapshotGate)
        await gate.failNextSnapshots(10)

        await harness.session.stop()
        XCTAssertFalse(harness.workspace.isPerforming)
        XCTAssertNil(harness.workspace.quickStartStartingRun)
        guard case .refreshFailed = harness.workspace.quickStartStatus else {
            return XCTFail("A failed terminal refresh must leave reload reachable.")
        }
    }

    func testStaleQuickStartInterruptReconcileCannotClearANewerOwner() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [
                NovelModelScript(steps: [.pause]),
                NovelModelScript(steps: [
                    .delta(quickStartSuggestionsJSON),
                    .pause,
                    .complete,
                ]),
            ],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        let firstStartedRunID = await harness.workspace.startQuickStartSuggestions()
        let firstRunID = try XCTUnwrap(firstStartedRunID)
        let firstBecameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == firstRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(firstBecameDurable)

        await gate.blockInterruptReturn()
        let oldInterrupt = Task { @MainActor () -> Error? in
            do {
                try await harness.workspace.interruptSessionRun(NovelCancelRunCommand(
                    context: NovelMutationContext(
                        operationID: NovelOperationID(),
                        expectedProjectRevision: nil,
                        expectedConfigRevision: nil,
                        expectedBranchHeadRevision: nil
                    ),
                    projectID: harness.projectID,
                    runID: firstRunID,
                    reason: .user
                ))
                return nil
            } catch {
                return error
            }
        }
        let interruptReturnedFromBase = await eventually {
            await gate.interruptReturnIsBlocked()
        }
        XCTAssertTrue(interruptReturnedFromBase)
        try await harness.workspace.refreshCurrentSelection(projectID: harness.projectID)
        XCTAssertTrue(harness.workspace.projectSnapshot?.activeRuns.contains(where: {
            $0.id == firstRunID && $0.status == .interrupted
        }) == true)

        await gate.blockNextSnapshot()
        await gate.resumeBlockedInterruptReturn()
        let oldRefreshBlocked = await eventually {
            await gate.snapshotIsBlocked()
        }
        XCTAssertTrue(oldRefreshBlocked)

        let secondStartedRunID = await harness.workspace.startQuickStartSuggestions()
        let secondRunID = try XCTUnwrap(secondStartedRunID)
        let secondBecameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == secondRunID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(secondBecameDurable)

        await gate.resumeBlockedSnapshot()
        let oldInterruptError = await oldInterrupt.value
        XCTAssertNil(oldInterruptError)
        XCTAssertEqual(harness.workspace.projectSnapshot?.branches.first?.activeRunID, secondRunID)
        guard case .generating(let ownerID) = harness.workspace.quickStartStatus else {
            return XCTFail("The newer Quick Start must remain the active owner.")
        }
        XCTAssertEqual(ownerID, secondRunID)

        await harness.adapter.resume(runID: secondRunID)
        let secondCompleted = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == secondRunID && $0.status == .completed
            }) == true && harness.workspace.projectSnapshot?.settingProposals.count == 4
        }
        XCTAssertTrue(secondCompleted)
    }

    func testQuickStartTerminalCleanupDoesNotReleaseAnotherMutationBusyState() async throws {
        let harness = try await makeHarness(
            document: try quickStartDocument(),
            scripts: [NovelModelScript(steps: [
                .delta(quickStartSuggestionsJSON),
                .pause,
                .complete,
            ])],
            usesSnapshotGate: true
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        let startedRunID = await harness.workspace.startQuickStartSuggestions()
        let runID = try XCTUnwrap(startedRunID)
        let becameDurable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)

        await gate.blockNextSnapshot()
        await harness.adapter.resume(runID: runID)
        let terminalRefreshBlocked = await eventually {
            await gate.snapshotIsBlocked()
        }
        XCTAssertTrue(terminalRefreshBlocked)

        await gate.blockNextPerform()
        let renameTask = Task { @MainActor in
            await harness.workspace.renameProject("并行改名")
        }
        let renameBlocked = await eventually {
            await gate.performIsBlocked()
        }
        XCTAssertTrue(renameBlocked)
        XCTAssertTrue(harness.workspace.isPerforming)

        await gate.resumeBlockedSnapshot()
        let quickStartFinished = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .completed
            }) == true
        }
        XCTAssertTrue(quickStartFinished)
        XCTAssertTrue(
            harness.workspace.isPerforming,
            "Quick Start cleanup must not release a newer mutation's busy state."
        )

        await gate.resumeBlockedPerform()
        await renameTask.value
        XCTAssertFalse(harness.workspace.isPerforming)
    }

    func testTerminalRefreshFailureKeepsFinalContentWithoutPretendingToStream() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.delta("已经完成的正文"), .pause, .complete])],
            usesSnapshotGate: true
        )
        harness.session.mode = .writeProse
        let didStart = await harness.session.send(text: "写一个片段")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually { harness.session.transientTail?.content == "已经完成的正文" }
        XCTAssertTrue(sawPartial)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let gate = try XCTUnwrap(harness.snapshotGate)

        await gate.failNextSnapshots(1)
        await harness.adapter.resume(runID: runID)
        let keptTerminalTail = await eventually {
            harness.session.refreshErrorMessage != nil && !harness.session.isRunning
        }
        XCTAssertTrue(keptTerminalTail)
        XCTAssertEqual(harness.session.transientTail?.content, "已经完成的正文")
        XCTAssertEqual(harness.session.transientTail?.phase, .terminalAwaitingRefresh)
        XCTAssertNil(harness.session.activeRunID)
        XCTAssertFalse(harness.session.canStop)

        let terminalProject = try XCTUnwrap(harness.workspace.projectSnapshot)
        let terminalBranch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let terminalList = try XCTUnwrap(
            harness.session.projectedListModel(project: terminalProject, branch: terminalBranch)
        )
        let terminalRunRowIDs = terminalList.activeRunRows.map(\.id)
        XCTAssertEqual(terminalRunRowIDs.count, 2)

        let didRefresh = await harness.session.refresh()
        XCTAssertTrue(didRefresh)
        XCTAssertNil(harness.session.transientTail)
        XCTAssertEqual(harness.session.durableMessages.last?.content, "已经完成的正文")
        let durableProject = try XCTUnwrap(harness.workspace.projectSnapshot)
        let durableBranch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let durableList = try XCTUnwrap(
            harness.session.projectedListModel(project: durableProject, branch: durableBranch)
        )
        XCTAssertNil(durableList.activeTailID)
        XCTAssertEqual(
            durableList.activeRunRows.map(\.id),
            terminalRunRowIDs,
            "Finished run must stay pinned in the active stack so the bubble is not reparented."
        )
        XCTAssertTrue(
            Set(terminalRunRowIDs).isDisjoint(with: Set(durableList.historicalRows.map(\.id))),
            "Pinned finished rows must not also appear in history."
        )
    }

}
