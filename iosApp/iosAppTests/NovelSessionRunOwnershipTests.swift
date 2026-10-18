import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionRunOwnershipTests: NovelSessionViewModelTestCase {
    func testDetachedWorkspaceConsumerDoesNotCancelAndRunStillPersistsCompletion() async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta("离开页面前的正文"),
            .pause,
            .delta("，后台继续完成。"),
            .complete,
        ])])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        let didStart = await harness.session.send(text: "开始生成后离开页面")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually {
            harness.session.transientTail?.content == "离开页面前的正文"
        }
        XCTAssertTrue(sawPartial)
        let runID = try XCTUnwrap(harness.session.activeRunID)

        harness.session.detachConsumer()
        let beforeResume = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(beforeResume.activeRuns.first { $0.id == runID }?.status, .running)
        let cancellationsBeforeResume = await harness.adapter.cancelledRunIDs
        XCTAssertFalse(cancellationsBeforeResume.contains(runID))

        await harness.adapter.resume(runID: runID)
        let persisted = await eventually {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.activeRuns.first { $0.id == runID }?.status == .completed
        }
        XCTAssertTrue(persisted)

        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.candidates.first?.content, "离开页面前的正文，后台继续完成。")
        let finalCancellations = await harness.adapter.cancelledRunIDs
        XCTAssertFalse(finalCancellations.contains(runID))
    }

    func testDetachWhileStartIsAwaitingDoesNotInstallLateConsumerOrBlockReturnToProject() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.delta("离页后完成的正文"), .pause, .complete])],
            usesAttachGate: true
        )
        let gate = try XCTUnwrap(harness.attachGate)
        let otherProject = try NovelTestFixtures.document()
        _ = try await harness.repository.createProject(otherProject)
        await gate.blockNextStart()

        let sendTask = Task { @MainActor in
            await harness.session.send(text: "启动握手期间离开页面")
        }
        let startBlocked = await eventually { await gate.startIsBlocked() }
        XCTAssertTrue(startBlocked)
        let runID = try XCTUnwrap(harness.session.activeRunID)

        harness.session.detachConsumer()
        await gate.resumeBlockedStart()
        let didStart = await sendTask.value
        XCTAssertTrue(didStart)

        await harness.workspace.loadProjects(selecting: otherProject.project.id)
        XCTAssertEqual(harness.workspace.selectedProjectID, otherProject.project.id)
        await harness.adapter.resume(runID: runID)
        let persisted = await eventually {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.activeRuns.first { $0.id == runID }?.status == .completed
        }
        XCTAssertTrue(persisted)

        await harness.workspace.loadProjects(selecting: harness.projectID)
        await harness.session.bindToCurrentSelection()

        XCTAssertNil(harness.session.transientTail)
        XCTAssertFalse(harness.session.isRunning)
        XCTAssertTrue(harness.session.canSend)
        XCTAssertNil(harness.session.refreshErrorMessage)
        XCTAssertEqual(harness.session.durableMessages.last?.content, "离页后完成的正文")
    }

    func testRebindWhileStartIsAwaitingRestoresConsumerWhenStartReturns() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.delta("重新出现后收到流"), .pause])],
            usesAttachGate: true
        )
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.blockNextStart()

        let sendTask = Task { @MainActor in
            await harness.session.send(text: "启动握手期间短暂离页")
        }
        let startBlocked = await eventually { await gate.startIsBlocked() }
        XCTAssertTrue(startBlocked)

        harness.session.detachConsumer()
        await harness.session.bindToCurrentSelection()
        await gate.resumeBlockedStart()
        let didStart = await sendTask.value
        XCTAssertTrue(didStart)

        let received = await eventually {
            harness.session.transientTail?.content == "重新出现后收到流"
        }
        XCTAssertTrue(received)
        XCTAssertNotNil(harness.session.activeRunID)
        await harness.session.stop()
    }

    func testAppBackgroundExpirationInterruptsRunAfterWorkspaceSelectsAnotherProject() async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(steps: [
            .delta("应保存的后台片段"),
            .pause,
        ])])
        harness.session.mode = .writeProse

        let didStart = await harness.session.send(text: "离开项目后继续生成")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually {
            harness.session.transientTail?.content == "应保存的后台片段"
        }
        XCTAssertTrue(sawPartial)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        harness.session.detachConsumer()

        let otherProject = try NovelTestFixtures.document()
        _ = try await harness.repository.createProject(otherProject)
        await harness.workspace.loadProjects(selecting: otherProject.project.id)
        XCTAssertEqual(harness.workspace.selectedProjectID, otherProject.project.id)

        await harness.workspace.interruptSessionForBackground(deadline: .distantPast)

        let didPersistInterruption = await eventually {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.activeRuns.first { $0.id == runID }?.status == .interrupted
        }
        XCTAssertTrue(didPersistInterruption)
        let original = try await harness.repository.loadProject(id: harness.projectID).document
        let run = try XCTUnwrap(original.activeRuns.first { $0.id == runID })
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.interruptionReason, .expiration)
        XCTAssertEqual(run.partialContent, "应保存的后台片段")
        XCTAssertEqual(original.sessions[0].messages.last?.kind, .interruptedDraft)
    }

    func testConcurrentRebindsKeepOneConsumerAndApplyEachDeltaOnce() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [
                .pause,
                .delta("只追加一次"),
                .pause,
            ])],
            usesAttachGate: true
        )
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "建立可恢复订阅")
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let durable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(durable)
        harness.session.detachConsumer()
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.blockNextStart()

        let firstBind = Task { @MainActor in
            await harness.session.bindToCurrentSelection()
        }
        let attachBlocked = await eventually { await gate.startIsBlocked() }
        XCTAssertTrue(attachBlocked)
        let secondBind = Task { @MainActor in
            await harness.session.bindToCurrentSelection()
        }
        await secondBind.value
        await gate.resumeBlockedStart()
        await firstBind.value

        await harness.adapter.resume(runID: runID)
        let received = await eventually {
            harness.session.transientTail?.content == "只追加一次"
        }
        XCTAssertTrue(received)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.session.transientTail?.content, "只追加一次")
        await harness.session.stop()
    }

    func testRefreshReattachesAfterActiveRunSubscriptionFails() async throws {
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [
                .pause,
                .delta("重新订阅后收到"),
                .pause,
            ])],
            usesAttachGate: true
        )
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "验证重新订阅")
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let durable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(durable)

        harness.session.detachConsumer()
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.failNextStart()
        await harness.session.bindToCurrentSelection()
        XCTAssertTrue(harness.session.hasRefreshError)
        XCTAssertNil(harness.session.transientTail)

        let refreshed = await harness.session.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertFalse(harness.session.hasRefreshError)
        XCTAssertEqual(harness.session.transientTail?.runID, runID)

        await harness.adapter.resume(runID: runID)
        let received = await eventually {
            harness.session.transientTail?.content == "重新订阅后收到"
        }
        XCTAssertTrue(received)
        await harness.session.stop()
    }

    func testStaleAttachCannotOverwriteANewerBranchBinding() async throws {
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let sourceBranchID = document.branches[0].id
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.pause])],
            usesAttachGate: true
        )
        await harness.workspace.forkBranch(
            from: sourceBranchID,
            checkpointID: document.branches[0].headCheckpointID,
            name: "新分支"
        )
        let destinationBranchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        await harness.workspace.selectBranch(sourceBranchID)
        await harness.session.bindToCurrentSelection()
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "旧分支运行")
        XCTAssertTrue(started)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let durable = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                $0.id == runID && $0.status == .running
            }) == true
        }
        XCTAssertTrue(durable)
        harness.session.detachConsumer()
        let gate = try XCTUnwrap(harness.attachGate)
        await gate.blockNextStart()

        let staleAttach = Task { @MainActor in
            await harness.session.bindToCurrentSelection()
        }
        let attachBlocked = await eventually { await gate.startIsBlocked() }
        XCTAssertTrue(attachBlocked)
        await harness.workspace.selectBranch(destinationBranchID)
        await harness.session.bindToCurrentSelection()
        await gate.resumeBlockedStart()
        await staleAttach.value

        XCTAssertEqual(harness.session.binding?.branchID, destinationBranchID)
        XCTAssertNil(harness.session.transientTail)
        XCTAssertNil(harness.session.refreshErrorMessage)
    }

    func testRebindCanonicalizesMultipleInjectionOverridesWithoutChangingRunIdentity() async throws {
        let fixture = try documentWithMaterials()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        harness.session.mode = .discussPlan
        let overrides = NovelInjectionOverrides(
            forceIncludeMaterialIDs: [fixture.materialIDs[1], fixture.materialIDs[0], fixture.materialIDs[1]],
            forceExcludeMaterialIDs: []
        )

        let didStart = await harness.session.send(
            text: "比较两份设定",
            injectionOverrides: overrides
        )
        XCTAssertTrue(didStart)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        let refreshedReceipt = await eventually {
            harness.workspace.projectSnapshot?.injectionReceipts.contains(where: {
                $0.runID == runID
            }) == true
        }
        XCTAssertTrue(refreshedReceipt)
        let receipt = try XCTUnwrap(harness.workspace.projectSnapshot?.injectionReceipts.last)
        XCTAssertEqual(receipt.forceIncludeMaterialIDs, fixture.materialIDs.sorted {
            $0.description < $1.description
        })

        harness.session.detachConsumer()
        await harness.session.bindToCurrentSelection()
        let reattached = await eventually {
            harness.session.activeRunID == runID && !harness.session.hasRefreshError
        }
        XCTAssertTrue(reattached)
        XCTAssertNil(harness.session.refreshErrorMessage)
        await harness.session.stop()
    }

    func testExplicitStopPersistsPartialAndRouteExitDoesNotDependOnConsumerCancellation() async throws {
        let harness = try await makeHarness(scripts: [NovelModelScript(
            steps: [.delta("保留的半段正文"), .pause, .delta("迟到内容"), .complete],
            ignoresCancellation: true
        )])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        let didStart = await harness.session.send(text: "先写一小段")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually {
            harness.session.transientTail?.content == "保留的半段正文"
        }
        XCTAssertTrue(sawPartial)
        let runID = try XCTUnwrap(harness.session.activeRunID)
        await harness.session.interruptForRouteExit()

        let document = try await harness.repository.loadProject(id: harness.projectID).document
        let run = try XCTUnwrap(document.activeRuns.first { $0.id == runID })
        XCTAssertEqual(run.status, .interrupted)
        XCTAssertEqual(run.interruptionReason, .routeExit)
        XCTAssertEqual(run.partialContent, "保留的半段正文")
        XCTAssertEqual(document.sessions[0].messages.last?.kind, .interruptedDraft)
        XCTAssertEqual(document.candidates.first?.status, .interrupted)
        XCTAssertEqual(document.candidates.first?.content, run.partialContent)
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertTrue(cancelledRunIDs.contains(runID))
    }

    func testUserStopFreezesVisibleTailUntilDurableProjectionIsWarm() async throws {
        let partial = String(repeating: "Mara crossed the archive. ", count: 80)
        let harness = try await makeHarness(
            scripts: [NovelModelScript(steps: [.delta(partial), .pause])],
            usesSnapshotGate: true,
            terminalQuietDelay: 0.8
        )
        let gate = try XCTUnwrap(harness.snapshotGate)
        harness.session.mode = .writeProse
        let started = await harness.session.send(text: "续写这一章")
        XCTAssertTrue(started)
        let pacerHasBacklog = await eventually {
            guard let visible = harness.session.transientTail?.content else { return false }
            return !visible.isEmpty && visible.count < partial.count
        }
        XCTAssertTrue(pacerHasBacklog)
        let tailBeforeStop = try XCTUnwrap(harness.session.transientTail)
        let runID = tailBeforeStop.runID

        await gate.blockInterruptReturn()
        let stopTask = Task { @MainActor in await harness.session.stop() }
        let interruptIsBlocked = await eventually {
            await gate.interruptReturnIsBlocked()
        }
        XCTAssertTrue(interruptIsBlocked)
        XCTAssertTrue(harness.session.isStopping)
        XCTAssertFalse(harness.session.canStop)
        XCTAssertEqual(harness.session.transientTail?.runID, runID)
        XCTAssertEqual(harness.session.transientTail?.content, tailBeforeStop.content)
        XCTAssertEqual(harness.session.transientTail?.phase, .interrupted)
        XCTAssertTrue(harness.session.isTerminalPresenting)

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(harness.session.transientTail?.content, tailBeforeStop.content)

        await gate.resumeBlockedInterruptReturn()
        await stopTask.value
        let durableContent = try XCTUnwrap(harness.workspace.branchSnapshot?.session.messages.first {
            $0.id == tailBeforeStop.messageID
        }?.content)
        XCTAssertFalse(harness.session.isStopping)
        XCTAssertEqual(harness.session.transientTail?.content, durableContent)
        XCTAssertEqual(harness.session.transientTail?.phase, .interrupted)
        XCTAssertEqual(
            harness.workspace.projectSnapshot?.activeRuns.first(where: { $0.id == runID })?.status,
            .interrupted
        )
        let warmed = try XCTUnwrap(harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertEqual(warmed.activeTailRow?.content, durableContent)

        let retired = await eventually(timeout: 3) { harness.session.transientTail == nil }
        XCTAssertTrue(retired, "The frozen tail should hand off after the durable projection quiet window.")
        let afterRetirement = try XCTUnwrap(harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertEqual(
            afterRetirement.rows.first { $0.id == tailBeforeStop.messageID }?.content,
            durableContent
        )
    }

    func testRetryIsBusyBeforeStartCompletesAndRejectsSecondTap() async throws {
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            scripts: [
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta("重试已启动"), .pause]),
            ],
            usesAttachGate: true
        )
        let gate = try XCTUnwrap(harness.attachGate)
        harness.session.mode = .writeProse
        let started = await harness.session.send(text: "续写")
        XCTAssertTrue(started)
        let failed = await eventually {
            harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed
        }
        XCTAssertTrue(failed)
        let runID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)

        await gate.blockNextStart()
        let retryTask = Task { @MainActor in
            await harness.session.retryGeneration(runID: runID)
        }
        let retryStartIsBlocked = await eventually {
            await gate.startIsBlocked()
        }
        XCTAssertTrue(retryStartIsBlocked)
        XCTAssertEqual(harness.session.retryingRunID, runID)
        XCTAssertTrue(harness.session.isBusy)
        let repeatedTap = await harness.session.retryGeneration(runID: runID)
        XCTAssertFalse(repeatedTap)

        await gate.resumeBlockedStart()
        let retryStarted = await retryTask.value
        XCTAssertTrue(retryStarted)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 2)
        await harness.session.stop()
    }

    func testInterruptedProseCanBeCollectedThenUndoneWithoutLeavingRetryAction() async throws {
        let partial = "Mara opened the archive.\n\nShe found a map."
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.delta(partial), .pause]),
            NovelModelScript(steps: [.delta(validDeltaJSON), .complete]),
        ])
        harness.session.mode = .writeProse
        harness.session.granularity = .wholeChapter

        let didStart = await harness.session.send(text: "写完整一章")
        XCTAssertTrue(didStart)
        let sawPartial = await eventually {
            harness.session.transientTail?.content == partial
        }
        XCTAssertTrue(sawPartial)
        await harness.session.stop()
        let persistedInterruption = await eventually {
            harness.workspace.projectSnapshot?.candidates.contains {
                $0.kind == .prose && $0.status == .interrupted
            } == true
        }
        XCTAssertTrue(persistedInterruption)

        let candidate = try XCTUnwrap(
            harness.workspace.projectSnapshot?.candidates.first {
                $0.kind == .prose && $0.status == .interrupted
            }
        )
        XCTAssertEqual(candidate.content, partial)
        let paragraphs = harness.session.paragraphs(candidateID: candidate.id)
        let collected = await harness.session.collectCandidate(
            candidate.id,
            selection: NovelParagraphSelection(paragraphIDs: paragraphs.map(\.id)),
            target: .createNextChapter(chapterID: NovelChapterID(), title: "新章")
        )
        XCTAssertTrue(collected)

        let collectedProject = try await harness.repository.loadProject(
            id: harness.projectID
        ).document
        XCTAssertEqual(
            collectedProject.candidates.first { $0.id == candidate.id }?.status,
            .collected
        )
        XCTAssertEqual(collectedProject.chapterVersions.last?.content, partial)
        XCTAssertEqual(collectedProject.branches[0].syncStatus, .synchronized)
        let projected = try XCTUnwrap(harness.session.projectedListModel(
            project: try XCTUnwrap(harness.workspace.projectSnapshot),
            branch: try XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertFalse(projected.rows.flatMap(\.actions).contains {
            if case .retryGeneration = $0.action { return true }
            return false
        })

        let syncCompleted = await eventually(timeout: 5) {
            harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized &&
                !harness.workspace.isPerforming
        }
        XCTAssertTrue(syncCompleted, harness.workspace.errorMessage ?? "收录后剧情状态未保持已同步")

        await harness.workspace.undoBranchHead()
        await harness.session.bindToCurrentSelection()
        let undone = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(undone.branches[0].headCheckpointID, candidate.baseCheckpointID)
    }

}
