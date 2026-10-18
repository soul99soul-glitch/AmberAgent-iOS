import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionRetryAndPolishTests: NovelSessionViewModelTestCase {
    func testExactRunRetryDoesNotRetryAStillNewerTerminalBubble() async throws {
        let retryableFailure = NovelModelFailure(
            code: "first_failed",
            message: "第一次失败",
            isRetryable: true
        )
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.fail(retryableFailure)]),
            NovelModelScript(steps: [.delta("第二次也中断"), .pause]),
            NovelModelScript(steps: [.delta("只重试第一条"), .complete]),
        ])
        harness.session.mode = .discussPlan
        let firstStarted = await harness.session.send(text: "第一条")
        XCTAssertTrue(firstStarted)
        let firstFinished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed
        }
        XCTAssertTrue(firstFinished)
        let firstRunID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.first?.id)

        let secondStarted = await harness.session.send(text: "第二条")
        XCTAssertTrue(secondStarted)
        let sawSecondPartial = await eventually {
            harness.session.transientTail?.content == "第二次也中断"
        }
        XCTAssertTrue(sawSecondPartial)
        let secondRunID = try XCTUnwrap(harness.session.transientTail?.runID)
        await harness.session.stop()
        let secondFinished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.contains(where: {
                    $0.id == secondRunID && $0.status == .interrupted
                }) == true
        }
        XCTAssertTrue(secondFinished)

        let didRetryFirst = await harness.session.retryGeneration(runID: firstRunID)
        XCTAssertTrue(didRetryFirst)
        let retryFinished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .completed &&
                harness.session.durableMessages.last?.content == "只重试第一条"
        }
        XCTAssertTrue(retryFinished)
        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.sessions[0].messages.last?.content, "只重试第一条")
        XCTAssertEqual(final.sessions[0].messages.last?.runID, final.activeRuns.last?.id)
        XCTAssertNotEqual(final.activeRuns.last?.id, secondRunID)
        let inputs = final.sessions[0].messages.filter { $0.role == .user }.map(\.content)
        XCTAssertEqual(inputs, ["第一条", "第二条", "第一条"])
    }

    func testProseRetryFailsClosedAfterBranchHeadMoves() async throws {
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            document: try NovelTestFixtures.documentWithForkableCheckpoint(),
            scripts: [
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta("不应生成"), .complete]),
            ]
        )
        harness.session.mode = .writeProse
        let started = await harness.session.send(text: "续写")
        XCTAssertTrue(started)
        let finished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.session.canRetryLastTerminal
        }
        XCTAssertTrue(finished)
        let runID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)

        await harness.workspace.undoBranchHead()
        XCTAssertFalse(harness.session.canRetryLastTerminal)
        let retried = await harness.session.retryGeneration(runID: runID)
        let bannerRetried = await harness.session.retryLastTerminal()
        let requests = await harness.adapter.requests
        XCTAssertFalse(retried)
        XCTAssertFalse(bannerRetried)
        XCTAssertEqual(requests.count, 1)
    }

    func testRegenerationRetryIsUnavailableAfterBranchHeadMoves() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.fail(failure)])]
        )

        let started = await harness.session.startWholeChapterRegeneration(chapterID: fixture.chapterID)
        XCTAssertTrue(started)
        let finished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.session.canRetryLastTerminal
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(harness.session.canRetryLastTerminal)

        await harness.workspace.undoBranchHead()
        XCTAssertFalse(
            harness.session.canRetryLastTerminal,
            "整章重新生成必须和正文重试一样绑定原 branch head，不能在新 head 上伪装成精确重试"
        )
    }

    func testRegenerationRetryTracksSourceChapterDiscardAndRestore() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.fail(failure)])]
        )

        let started = await harness.session.startWholeChapterRegeneration(chapterID: fixture.chapterID)
        XCTAssertTrue(started)
        let finished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.session.canRetryLastTerminal
        }
        XCTAssertTrue(finished)
        let runID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)
        XCTAssertTrue(harness.session.canRetryLastTerminal)

        await harness.workspace.setChapterDiscarded(true, chapterID: fixture.chapterID)

        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertNotNil(
            persisted.chapters.first(where: { $0.id == fixture.chapterID })?.discardedAt,
            harness.workspace.errorMessage ?? "The chapter discard did not persist."
        )
        XCTAssertFalse(harness.session.canRetryLastTerminal)
        let retried = await harness.session.retryGeneration(runID: runID)
        XCTAssertFalse(retried)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)

        await harness.workspace.setChapterDiscarded(false, chapterID: fixture.chapterID)
        let restored = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertNil(restored.chapters.first(where: { $0.id == fixture.chapterID })?.discardedAt)
        XCTAssertTrue(harness.session.canRetryLastTerminal)
    }

    func testDiscussionRetryRemainsAllowedAfterBranchHeadMoves() async throws {
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            document: try NovelTestFixtures.documentWithForkableCheckpoint(),
            scripts: [
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta("新 head 上的讨论"), .complete]),
            ]
        )
        harness.session.mode = .discussPlan
        let started = await harness.session.send(text: "讨论一下")
        XCTAssertTrue(started)
        let firstFinished = await eventually { !harness.session.isRunning }
        XCTAssertTrue(firstFinished)
        let runID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)

        await harness.workspace.undoBranchHead()
        let retried = await harness.session.retryGeneration(runID: runID)
        XCTAssertTrue(retried)
        let retryFinished = await eventually {
            harness.session.durableMessages.last?.content == "新 head 上的讨论"
        }
        XCTAssertTrue(retryFinished)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 2)
    }

    /// 端到端红线:这两条断言各自对应一个曾把整个功能做成死代码的缺陷。
    /// (1) prose run 的形状校验禁止携带 sourceChapterVersionID → 发起必失败;
    /// (2) .proseWholeChapter 的注入分支只取「最后一章的结尾」,被重写的那一章
    ///     根本不进上下文 → 模型只能凭标题瞎编,再被默认选项收录去覆盖原章。
    func testWholeChapterRegenerationStartsAndInjectsTheChapterBeingRewritten() async throws {
        let fixture = try documentWithChapter()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.delta("重写后的正文。"), .complete])]
        )

        let started = await harness.session.startWholeChapterRegeneration(chapterID: fixture.chapterID)
        XCTAssertTrue(started, "整章重新生成必须能真的发起")

        let finished = await eventually { !harness.session.isRunning }
        XCTAssertTrue(finished)

        let requests = await harness.adapter.requests
        let prompt = try XCTUnwrap(requests.first).messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(
            prompt.contains("Mara crossed the hall. The gate stayed closed."),
            "被重写章的完整正文必须进入上下文，否则模型只能凭标题瞎编"
        )
    }

    func testPolishRetryFailsClosedAfterSourceChapterChanges() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(code: "retryable", message: "暂时失败", isRetryable: true)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta("不应润色"), .complete]),
            ]
        )
        let started = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        XCTAssertTrue(started)
        let finished = await eventually {
            harness.session.transientTail == nil &&
                harness.workspace.projectSnapshot?.activeRuns.last?.status == .failed &&
                harness.session.canRetryLastTerminal
        }
        XCTAssertTrue(finished)
        let runID = try XCTUnwrap(harness.workspace.projectSnapshot?.activeRuns.last?.id)

        let saved = await harness.workspace.saveManualRewrite(
            chapterID: fixture.chapterID,
            title: "第一章",
            content: "剧情已被手动改写。"
        )
        XCTAssertTrue(saved)
        let retried = await harness.session.retryGeneration(runID: runID)
        let requests = await harness.adapter.requests
        XCTAssertFalse(retried)
        XCTAssertEqual(requests.count, 1)
    }

    func testWholeChapterPolishAdoptsCompatibleCandidate() async throws {
        let fixture = try documentWithChapter()
        let polished = "Mara crossed the quiet hall."
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [
                    .delta("\(polished)\n\(NovelPromptCatalog.polishCompletionSentinel)"),
                    .complete,
                ]),
                NovelModelScript(steps: [.delta(compatibleDriftJSON), .complete]),
            ]
        )
        let didStart = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        XCTAssertTrue(didStart)
        let sawCandidate = await eventually { !harness.session.availablePolishCandidates.isEmpty }
        XCTAssertTrue(sawCandidate)
        let candidate = try XCTUnwrap(harness.session.availablePolishCandidates.first)
        await harness.session.adoptPolishCandidate(candidate.id)

        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.candidates.first { $0.id == candidate.id }?.status, .adopted)
        XCTAssertEqual(
            final.polishTransactions.first { $0.candidateID == candidate.id }?.status,
            .completed
        )
        XCTAssertEqual(final.chapterVersions.last?.kind, .polish)
        XCTAssertEqual(final.chapterVersions.last?.content, polished)
        XCTAssertEqual(final.chapterVersions.last?.sourceCandidateID, candidate.id)
        let finalState = try XCTUnwrap(final.stateSnapshots.first {
            $0.id == final.branches[0].currentStateSnapshotID
        })
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(
            finalState.chapterPlots.first { $0.chapterID == fixture.chapterID }?.text,
            NovelWorkspaceLedger.excerpt(title: "第一章", content: polished)
        )
    }

    func testUnresolvedPolishTransactionBlocksStartingAnotherPolishOrRegeneration() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(
            code: "provider_down",
            message: "漂移检查失败",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [
                    .delta("Mara crossed the quiet hall.\n\(NovelPromptCatalog.polishCompletionSentinel)"),
                    .complete,
                ]),
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.pause]),
            ]
        )

        let started = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        XCTAssertTrue(started)
        let candidateArrived = await eventually { !harness.session.availablePolishCandidates.isEmpty }
        XCTAssertTrue(candidateArrived)
        let candidate = try XCTUnwrap(harness.session.availablePolishCandidates.first)
        await harness.session.adoptPolishCandidate(candidate.id)
        XCTAssertEqual(harness.session.unresolvedBranchPolishTransactions.count, 1)

        let secondPolish = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        let regeneration = await harness.session.startWholeChapterRegeneration(chapterID: fixture.chapterID)
        if secondPolish || regeneration { await harness.session.stop() }

        XCTAssertFalse(secondPolish)
        XCTAssertFalse(regeneration)
        let requestCount = await harness.adapter.requests.count
        XCTAssertEqual(requestCount, 2, "未解决润色事务不得再消耗一次正文生成请求")
    }

    func testPolishRetryOwnerSurvivesSessionViewRemountAndCanStillStop() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(
            code: "provider_down",
            message: "漂移检查失败",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [
                    .delta("Mara crossed the quiet hall.\n\(NovelPromptCatalog.polishCompletionSentinel)"),
                    .complete,
                ]),
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.pause]),
            ]
        )
        let started = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        XCTAssertTrue(started)
        let candidateArrived = await eventually {
            !harness.session.availablePolishCandidates.isEmpty
        }
        XCTAssertTrue(candidateArrived)
        let candidate = try XCTUnwrap(harness.session.availablePolishCandidates.first)
        await harness.session.adoptPolishCandidate(candidate.id)
        let transactionID = try XCTUnwrap(
            harness.session.unresolvedBranchPolishTransactions.first?.id
        )

        XCTAssertTrue(harness.session.startPolishRetry(transactionID))
        let retryStarted = await eventually { await harness.adapter.requests.count == 3 }
        XCTAssertTrue(retryStarted)
        await harness.session.bindToCurrentSelection()
        XCTAssertEqual(harness.session.polishRetryTransactionID, transactionID)

        harness.session.cancelPolishRetry()
        let retryStopped = await eventually {
            harness.session.polishRetryTransactionID == nil && !harness.workspace.isPerforming
        }
        XCTAssertTrue(retryStopped)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.polishTransactions.first?.status, .retryable)
    }

    func testCancelledPolishRetryReconcilesBatchReportWhenFinalCommitAlreadyCompleted() async throws {
        let fixture = try documentWithChapter()
        let failure = NovelModelFailure(
            code: "provider_down",
            message: "漂移检查失败",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [
                    .delta("Mara crossed the quiet hall.\n\(NovelPromptCatalog.polishCompletionSentinel)"),
                    .complete,
                ]),
                NovelModelScript(steps: [.fail(failure)]),
                NovelModelScript(steps: [.delta(compatibleDriftJSON), .complete]),
            ],
            usesPerformReturnGate: true
        )
        XCTAssertTrue(harness.session.startBatchPolish(chapterIDs: [fixture.chapterID]))
        let batchFinished = await eventually {
            harness.session.batchPolishProgress?.phase == .done
        }
        XCTAssertTrue(batchFinished)
        XCTAssertEqual(harness.session.batchPolishProgress?.failedCount, 1)
        let transactionID = try XCTUnwrap(
            harness.session.unresolvedBranchPolishTransactions.first?.id
        )
        let gate = try XCTUnwrap(harness.performReturnGate)
        await gate.blockNextAdoptionReturn()

        XCTAssertTrue(harness.session.startPolishRetry(transactionID))
        await gate.waitUntilAdoptionReturnBlocked()
        let durableBeforeCancel = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(durableBeforeCancel.polishTransactions.first?.status, .completed)

        harness.session.cancelPolishRetry()
        await gate.resumeAdoptionReturn()
        let retryFinished = await eventually {
            harness.session.polishRetryTransactionID == nil
        }
        XCTAssertTrue(retryFinished)
        XCTAssertEqual(harness.session.batchPolishProgress?.adoptedCount, 1)
        XCTAssertEqual(harness.session.batchPolishProgress?.failedCount, 0)
    }

    func testIncompatiblePolishCanConvertToManualRewriteAndStaysSynchronized() async throws {
        let fixture = try documentWithChapter()
        let rewritten = "Mara opened the gate and changed the plot."
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [
                    .delta("\(rewritten)\n\(NovelPromptCatalog.polishCompletionSentinel)"),
                    .complete,
                ]),
                NovelModelScript(steps: [.delta(incompatibleDriftJSON), .complete]),
            ],
            usesSnapshotGate: true
        )

        let didStart = await harness.session.startWholeChapterPolish(chapterID: fixture.chapterID)
        XCTAssertTrue(didStart)
        let sawCandidate = await eventually { !harness.session.availablePolishCandidates.isEmpty }
        XCTAssertTrue(sawCandidate)
        let candidate = try XCTUnwrap(harness.session.availablePolishCandidates.first)
        await harness.session.adoptPolishCandidate(candidate.id)
        let beforeConversion = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            beforeConversion.candidates.first { $0.id == candidate.id }?.status,
            .superseded
        )
        XCTAssertEqual(
            beforeConversion.polishTransactions.first { $0.candidateID == candidate.id }?.status,
            .incompatible
        )
        let manualVersionCount = beforeConversion.chapterVersions.filter { $0.kind == .manualEdit }.count
        await harness.snapshotGate?.failNextBranchSnapshots(2)
        let converted = await harness.session.convertPolishCandidateToManualRewrite(candidate.id)
        XCTAssertTrue(converted)

        let final = try await harness.repository.loadProject(id: harness.projectID).document
        // Contract v1.1 D-B: the converted manual rewrite commits its plot
        // module atomically, so the branch stays synchronized.
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(final.chapterVersions.last?.kind, .manualEdit)
        XCTAssertEqual(final.chapterVersions.last?.content, rewritten)
        XCTAssertEqual(
            final.chapterVersions.filter { $0.kind == .manualEdit }.count,
            manualVersionCount + 1
        )
        XCTAssertNil(harness.workspace.errorMessage)
        XCTAssertNotNil(harness.workspace.reloadNoticeMessage)
        XCTAssertTrue(harness.workspace.requiresReload)
        await harness.workspace.retryCommittedMutationReload()
        XCTAssertFalse(harness.workspace.requiresReload)
        let afterReload = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            afterReload.chapterVersions.filter { $0.kind == .manualEdit }.count,
            manualVersionCount + 1
        )
    }
}
