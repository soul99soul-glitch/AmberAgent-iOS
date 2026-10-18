import SwiftUI
import XCTest
@testable import SwiftStreamingMarkdown
@testable import iosApp

@MainActor
final class NovelSessionManualSyncTests: NovelSessionViewModelTestCase {
    func testSelectedStableParagraphCollectsAndCommitsFacts() async throws {
        let prose = "Mara opened the archive.\n\nShe found a map."
        let harness = try await makeHarness(scripts: [
            NovelModelScript(steps: [.delta(prose), .complete]),
            NovelModelScript(steps: [.delta(validDeltaJSON), .complete]),
        ])
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation
        let didStart = await harness.session.send(text: "续写档案馆")
        XCTAssertTrue(didStart)
        let sawCandidate = await eventually { !harness.session.availableProseCandidates.isEmpty }
        XCTAssertTrue(sawCandidate)
        let candidate = try XCTUnwrap(harness.session.availableProseCandidates.first)
        let paragraphs = harness.session.paragraphs(candidateID: candidate.id)
        XCTAssertEqual(paragraphs.count, 2)

        let collected = await harness.session.collectCandidate(
            candidate.id,
            selection: NovelParagraphSelection(paragraphIDs: [paragraphs[0].id]),
            target: .createNextChapter(chapterID: NovelChapterID(), title: "第一章")
        )
        XCTAssertTrue(collected)

        let final = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(final.chapterVersions.last?.content, paragraphs[0].text)
        XCTAssertEqual(final.candidates.first { $0.id == candidate.id }?.status, .collected)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.checkpoints.last?.kind, .collection)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)

        let syncCompleted = await eventually {
            harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized &&
                !harness.workspace.isPerforming
        }
        XCTAssertTrue(syncCompleted)

        // 收录当时已抽完状态，一次 undo 就是撤回这次收录。
        await harness.workspace.undoBranchHead()
        await harness.session.bindToCurrentSelection()
        let undone = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(undone.branches[0].headCheckpointID, candidate.baseCheckpointID)
        XCTAssertEqual(
            undone.candidates.first { $0.id == candidate.id }?.status,
            .collected
        )
        let clonedCandidateID = await harness.session.cloneCollectedProse(candidate.id)
        let clonedID = try XCTUnwrap(clonedCandidateID)
        var clonedDocument = try await harness.repository.loadProject(id: harness.projectID).document
        clonedDocument.project.lastGenerationGranularity = .wholeChapter
        harness.workspace.projectSnapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: clonedDocument,
            access: .readWrite
        ))

        XCTAssertEqual(harness.session.collectionGranularity(for: clonedID), .continuation)
    }

    /// Contract v1.1 D-B: saving a manual rewrite commits the chapter and
    /// its plot module atomically — the branch stays synchronized and no
    /// follow-up automatic sync is scheduled (the previous contract let the
    /// edit land as needsSync first).
    func testManualRewriteCommitsPlotAtomicallyWithoutFollowUpSync() async throws {
        let fixture = try documentWithChapter()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: []
        )

        let saved = await harness.workspace.saveManualRewrite(
            chapterID: fixture.chapterID,
            title: "第一章",
            content: "Mara opened the archive."
        )
        XCTAssertTrue(saved)

        let after = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(after.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(after.checkpoints.last?.kind, .manualSync)
        XCTAssertTrue(after.pendingOperations.isEmpty)
        XCTAssertTrue(harness.session.retryableBranchPendingOperations.isEmpty)
        XCTAssertNil(harness.workspace.stateSyncActivity)

        // Latest-chapter plot relinking is deterministic; no model or follow-up sync runs.
        try? await Task.sleep(for: .milliseconds(350))
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// 改过非末章留下的过期标记由工作区自动「按正文接受」（作者已确认过改动，
    /// 不再要求手动点按钮）：标记清除、提示编号递增，后续写作不再被拦。
    /// 领域层门禁本身仍在，作为自动同步失败时的兜底，见 NovelFactTransactionLifecycleTests。
    func testStalePlotIsAutoAcceptedAndUnblocksForwardRuns() async throws {
        var fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let chapterID = branch.workingChapterSelections[0].chapterID
        if let index = fixture.document.stateSnapshots.firstIndex(where: {
            $0.id == branch.currentStateSnapshotID
        }) {
            let old = fixture.document.stateSnapshots[index]
            fixture.document.stateSnapshots[index] = NovelStateSnapshotRecord(
                id: old.id,
                eventIDs: old.eventIDs,
                summary: old.summary,
                branchOutline: old.branchOutline,
                unresolvedEntityNames: old.unresolvedEntityNames,
                createdAt: old.createdAt,
                settingProposalIDs: old.settingProposalIDs,
                characterIdentityClarifications: old.characterIdentityClarifications,
                recentWrittenHighlights: old.recentWrittenHighlights,
                chapterPlots: [
                    NovelChapterPlotModule(
                        chapterID: chapterID,
                        text: old.chapterPlots.first?.text ?? "山呼",
                        stale: true
                    )
                ]
            )
        }
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: []
        )

        let synced = await eventually {
            !harness.workspace.hasStalePlot && harness.workspace.stalePlotAutoSyncNoticeID == 1
        }
        XCTAssertTrue(synced, "过期标记应被自动接受，并发出一次轻提示")
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        let state = try XCTUnwrap(persisted.stateSnapshots.first {
            $0.id == persisted.branches.first(where: { $0.id == branch.id })?.currentStateSnapshotID
        })
        XCTAssertFalse(state.hasStaleChapterPlots, "自动接受必须落盘，而不只是界面状态")
        XCTAssertFalse(NovelGhostwriteReadiness.issues(
            in: persisted,
            branchID: branch.id,
            requireChapterPlan: false
        ).contains(.unresolvedPlot))
    }

    func testPersistedNeedsSyncWaitsForWorkspaceAppearanceBeforeAutomaticStateSync() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let document = try NovelReducer.apply(.saveManualEdit(NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: fixture.document.project.revision,
                expectedConfigRevision: fixture.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branch.id,
            chapterID: fixture.chapterID,
            versionID: NovelChapterVersionID(),
            title: "第一章",
            content: "Mara opened the archive.",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )), to: fixture.document).document
        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .complete,
            ])]
        )

        try? await Task.sleep(for: .milliseconds(350))
        let requestsBeforeAppearance = await harness.adapter.requests
        XCTAssertEqual(requestsBeforeAppearance.count, 0)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let syncCompleted = await eventually {
            let project = try? await harness.repository.loadProject(id: harness.projectID).document
            return project?.branches[0].syncStatus == .synchronized
        }
        XCTAssertTrue(syncCompleted)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testWorkspaceAppearanceResumesPersistedPendingManualSync() async throws {
        try await assertPersistedManualSyncResumes(status: .pending)
    }

    func testWorkspaceAppearanceHealsRetryableManualSyncWithPreviousError() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .complete,
            ])]
        )

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let syncCompleted = await eventually(timeout: 5) {
            let project = try? await harness.repository.loadProject(id: harness.projectID).document
            return project?.pendingOperations.isEmpty == true &&
                project?.branches[0].syncStatus == .synchronized
        }
        XCTAssertTrue(syncCompleted, "retryable manual sync must resume from its durable pending")
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRetryableManualSyncBlocksGeneratingANewProseCandidate() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta("我们可以先确认这段改写对后续伏笔的影响。"),
                .complete,
            ])]
        )
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.syncStatus, .needsSync)
        XCTAssertEqual(harness.session.composerSendKind, .discussion)
        XCTAssertTrue(harness.session.canSend)
        let didStart = await harness.session.send(text: "继续写她进入档案馆")
        XCTAssertTrue(didStart)
        let discussionSettled = await eventually { !harness.session.isRunning }
        XCTAssertTrue(discussionSettled)

        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.pendingOperations.first?.id, fixture.pendingID)
        XCTAssertEqual(persisted.pendingOperations.first?.status, .retryable)
        XCTAssertTrue(persisted.candidates.isEmpty)
        XCTAssertEqual(persisted.sessions[0].messages.last?.mode, .discussPlan)
    }

    func testRetryableManualSyncCandidateCanBeCollectedAfterSuccessfulRetry() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let prose = "Mara pushed open the archive door."
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.delta(validRebuildJSON), .complete]),
                NovelModelScript(steps: [.delta(prose), .complete]),
                NovelModelScript(steps: [.delta(validDeltaJSON), .complete]),
                NovelModelScript(steps: [.delta(validDeltaJSON), .complete]),
            ]
        )
        harness.session.mode = .writeProse
        harness.session.granularity = .continuation

        // Formal prose stays blocked until the stale branch state is synchronized;
        // the composer still sends discussion so the input is not dead.
        XCTAssertEqual(harness.session.composerSendKind, .discussion)
        XCTAssertTrue(harness.session.canSend)
        await harness.workspace.retryPending(fixture.pendingID)
        let synchronized = await eventually {
            harness.workspace.projectSnapshot?.pendingOperations.isEmpty == true &&
                harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized
        }
        XCTAssertTrue(synchronized)

        let didStart = await harness.session.send(text: "继续写她进入档案馆")
        XCTAssertTrue(didStart)
        let generated = await eventually {
            !harness.session.availableProseCandidates.isEmpty && !harness.session.isRunning
        }
        XCTAssertTrue(generated)
        let candidate = try XCTUnwrap(harness.session.availableProseCandidates.first)

        let project = try XCTUnwrap(harness.workspace.projectSnapshot)
        let branch = try XCTUnwrap(harness.workspace.branchSnapshot)
        let collectAction = harness.session.projectedListModel(
            project: project,
            branch: branch
        )?.rows.flatMap(\.actions).first {
            $0.action == .collectProse(candidate.id)
        }
        XCTAssertNil(collectAction?.blocker)

        let paragraphs = harness.session.paragraphs(candidateID: candidate.id)
        let collected = await harness.session.collectCandidate(
            candidate.id,
            selection: NovelParagraphSelection(paragraphIDs: paragraphs.map(\.id)),
            target: .appendToChapter(try XCTUnwrap(fixture.document.chapters.first?.id))
        )
        XCTAssertTrue(collected)

        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            persisted.candidates.first { $0.id == candidate.id }?.status,
            .collected
        )
        XCTAssertTrue(persisted.chapterVersions.contains {
            $0.sourceCandidateID == candidate.id && $0.content.contains(prose)
        })

        let collectionSynchronized = await eventually(timeout: 5) {
            harness.workspace.projectSnapshot?.pendingOperations.isEmpty == true &&
                harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized &&
                harness.workspace.projectSnapshot?.checkpoints.first(where: {
                    $0.id == harness.workspace.branchSnapshot?.branch.headCheckpointID
                })?.kind == .collection
        }
        XCTAssertTrue(collectionSynchronized)

        let rawHeadID = try XCTUnwrap(harness.workspace.branchSnapshot?.branch.headCheckpointID)
        let undoReady = await eventually {
            guard let project = harness.workspace.projectSnapshot,
                  let branch = harness.workspace.branchSnapshot,
                  let action = harness.session.projectedListModel(
                      project: project,
                      branch: branch
                  )?.rows.flatMap(\.actions).first(where: { action in
                      guard case .undoCommittedChange(let checkpointID, .prose) = action.action else {
                          return false
                      }
                      return checkpointID == rawHeadID
                  }) else { return false }
            return action.blocker == nil
        }
        XCTAssertTrue(
            undoReady,
            "tail=\(String(describing: harness.session.transientTail?.phase)) " +
                "activeRun=\(String(describing: harness.session.activeRunID)) " +
                "branchRun=\(String(describing: harness.workspace.branchSnapshot?.branch.activeRunID))"
        )

        await harness.workspace.undoBranchHead()
        await harness.session.bindToCurrentSelection()
        let clonedCandidateID = await harness.session.cloneCollectedProse(candidate.id)
        let clonedID = try XCTUnwrap(clonedCandidateID)
        let clonedParagraphs = harness.session.paragraphs(candidateID: clonedID)
        let recollected = await harness.session.collectCandidate(
            clonedID,
            selection: NovelParagraphSelection(paragraphIDs: clonedParagraphs.map(\.id)),
            target: .appendToChapter(try XCTUnwrap(fixture.document.chapters.first?.id))
        )
        XCTAssertTrue(recollected)
    }

    func testPendingManualSyncResumesThroughModelRebuild() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .complete,
            ])]
        )
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.syncStatus, .needsSync)
        XCTAssertFalse(harness.workspace.projectSnapshot?.pendingOperations.isEmpty ?? true)

        await harness.workspace.finishPlotRelinkIfNeeded()
        let synchronized = await eventually {
            harness.workspace.projectSnapshot?.pendingOperations.isEmpty == true &&
                harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized
        }
        XCTAssertTrue(synchronized, "durable manual sync must finish through its model rebuild")
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCollectBlocksCandidateWhileManualSyncIsPending() async throws {
        let fixture = try documentWithChapter()
        var document = fixture.document
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let content = "Mara crossed the quiet hall."
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: messageID,
                sequence: 0,
                role: .assistant,
                mode: .writeProse,
                kind: .proseCandidate,
                content: content,
                createdAt: document.project.updatedAt,
                runID: nil,
                candidateID: candidateID
            )
        ]
        document.sessions[0].revision = 1
        document.candidates.append(
            NovelCandidateRecord(
                id: candidateID,
                kind: .prose,
                branchID: document.branches[0].id,
                sessionID: document.branches[0].sessionID,
                sourceMessageID: messageID,
                baseCheckpointID: document.branches[0].headCheckpointID,
                baseHeadRevision: document.branches[0].headRevision,
                status: .available,
                content: content,
                sourceChapterVersionID: nil,
                collectedCheckpointID: nil,
                createdAt: document.project.updatedAt
            )
        )
        try NovelDocumentValidator.validate(document)
        document = try overlayRetryableManualSync(on: document)

        let harness = try await makeHarness(document: document, scripts: [])
        XCTAssertEqual(harness.workspace.branchSnapshot?.branch.syncStatus, .needsSync)

        let paragraphs = harness.session.paragraphs(candidateID: candidateID)
        let collected = await harness.session.collectCandidate(
            candidateID,
            selection: NovelParagraphSelection(paragraphIDs: paragraphs.map(\.id)),
            target: .appendToChapter(fixture.chapterID)
        )
        XCTAssertFalse(collected)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            persisted.candidates.first { $0.id == candidateID }?.status,
            .available
        )
        XCTAssertEqual(persisted.pendingOperations.count, 1)
        XCTAssertEqual(persisted.branches[0].syncStatus, .needsSync)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCollectFinishesPointerOnlyRelinkBeforeTakingSessionMutationLock() async throws {
        let fixture = try documentWithChapter()
        var document = fixture.document
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let content = "Mara crossed the quiet hall."
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: messageID,
                sequence: 0,
                role: .assistant,
                mode: .writeProse,
                kind: .proseCandidate,
                content: content,
                createdAt: document.project.updatedAt,
                runID: nil,
                candidateID: candidateID
            )
        ]
        document.sessions[0].revision = 1
        document.candidates.append(
            NovelCandidateRecord(
                id: candidateID,
                kind: .prose,
                branchID: document.branches[0].id,
                sessionID: document.branches[0].sessionID,
                sourceMessageID: messageID,
                baseCheckpointID: document.branches[0].headCheckpointID,
                baseHeadRevision: document.branches[0].headRevision,
                status: .available,
                content: content,
                sourceChapterVersionID: nil,
                collectedCheckpointID: nil,
                createdAt: document.project.updatedAt
            )
        )
        document.branches[0].syncStatus = .needsSync
        try NovelDocumentValidator.validate(document)

        let harness = try await makeHarness(
            document: document,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON), .complete])]
        )
        let paragraphs = harness.session.paragraphs(candidateID: candidateID)
        let collected = await harness.session.collectCandidate(
            candidateID,
            selection: NovelParagraphSelection(paragraphIDs: paragraphs.map(\.id)),
            target: .appendToChapter(fixture.chapterID)
        )

        XCTAssertTrue(collected)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            persisted.candidates.first { $0.id == candidateID }?.status,
            .collected
        )
        XCTAssertTrue(persisted.pendingOperations.isEmpty)
        XCTAssertEqual(persisted.branches[0].syncStatus, .synchronized)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 0, "pointer relink and fast-forward collection are deterministic")
    }

    func testExplicitManualSyncRetryPublishesDurableProgressUntilTerminal() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .pause,
                .complete,
            ])]
        )
        let chapters = try NovelFactTransactionReducer.decodeManualPayload(
            try XCTUnwrap(fixture.document.pendingOperations.first?.selectedText)
        )
        let expectedCharacterCount = NovelFactTransactionReducer
            .manualRebuildManuscript(chapters)
            .count

        let retryTask = Task { @MainActor in
            await harness.workspace.retryPending(fixture.pendingID)
        }

        let progressPublished = await eventually(timeout: 3) {
            guard let activity = harness.workspace.stateSyncActivity else { return false }
            return activity.phase == .analyzing &&
                activity.pendingID == fixture.pendingID &&
                activity.completedCharacters == 0 &&
                activity.totalCharacters == expectedCharacterCount &&
                activity.completionFraction == 0 &&
                activity.requestStartedAt != nil
        }
        XCTAssertTrue(progressPublished)

        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        await harness.adapter.resume(runID: request.runID)
        await retryTask.value

        XCTAssertNil(harness.workspace.stateSyncActivity)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertTrue(persisted.pendingOperations.isEmpty)
        XCTAssertEqual(persisted.branches[0].syncStatus, .synchronized)
    }

    /// The session view model's `retryPending` is the entry point the "重试" button in
    /// `NovelSessionView` actually calls (not `workspace.retryPending`). It must publish the
    /// same durable `stateSyncActivity` progress as the already-wired workspace-level retry.
    func testSessionRetryPendingPublishesStateSyncActivityForManualSync() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .pause,
                .complete,
            ])]
        )
        let chapters = try NovelFactTransactionReducer.decodeManualPayload(
            try XCTUnwrap(fixture.document.pendingOperations.first?.selectedText)
        )
        let expectedCharacterCount = NovelFactTransactionReducer
            .manualRebuildManuscript(chapters)
            .count

        let retryTask = Task { @MainActor in
            await harness.session.retryPending(fixture.pendingID)
        }

        let progressPublished = await eventually(timeout: 3) {
            guard let activity = harness.workspace.stateSyncActivity else { return false }
            return activity.phase == .analyzing &&
                activity.pendingID == fixture.pendingID &&
                activity.completedCharacters == 0 &&
                activity.totalCharacters == expectedCharacterCount &&
                activity.completionFraction == 0 &&
                activity.requestStartedAt != nil
        }
        XCTAssertTrue(progressPublished)

        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        await harness.adapter.resume(runID: request.runID)
        await retryTask.value

        XCTAssertNil(harness.workspace.stateSyncActivity)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertTrue(persisted.pendingOperations.isEmpty)
        XCTAssertEqual(persisted.branches[0].syncStatus, .synchronized)
    }

    func testSessionManualSyncRetryCanBeStoppedThroughSharedStateSyncControl() async throws {
        let fixture = try persistedManualSync(status: .retryable)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .pause,
                .complete,
            ])]
        )

        let retryTask = Task { @MainActor in
            await harness.session.retryPending(fixture.pendingID)
        }
        let requestStarted = await eventually(timeout: 3) {
            harness.workspace.stateSyncActivity?.requestStartedAt != nil
        }
        XCTAssertTrue(requestStarted)
        let branchID = try XCTUnwrap(harness.workspace.selectedBranchID)
        XCTAssertTrue(
            harness.workspace.canCancelAutomaticStateSync(
                projectID: harness.projectID,
                branchID: branchID
            ),
            "手动重试也必须被三处同步进度 UI 的停止按钮识别"
        )

        harness.workspace.cancelAutomaticStateSync(
            projectID: harness.projectID,
            branchID: branchID
        )
        await retryTask.value

        let stopped = await eventually(timeout: 3) {
            let cancelledRunIDs = await harness.adapter.cancelledRunIDs
            return !cancelledRunIDs.isEmpty &&
                harness.workspace.stateSyncActivity == nil &&
                !harness.workspace.isPerforming
        }
        XCTAssertTrue(stopped)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.pendingOperations.first?.id, fixture.pendingID)
        XCTAssertEqual(persisted.pendingOperations.first?.status, .retryable)
        XCTAssertEqual(persisted.branches[0].syncStatus, .needsSync)
    }

    /// `retryPending` is a generic retry entry point: pending operations can also be the
    /// `.collection` kind (legacy collection recovery), which never runs a state-sync model
    /// call. Retrying one of those must not publish a `stateSyncActivity`.
    func testSessionRetryPendingDoesNotPublishStateSyncActivityForNonManualSyncKind() async throws {
        let fixture = try documentWithChapter()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.complete])]
        )
        let branch = try XCTUnwrap(harness.workspace.branchSnapshot?.branch)
        let collectionPendingID = NovelPendingOperationID()
        let collectionPending = NovelPendingOperationRecord(
            id: collectionPendingID,
            kind: .collection,
            status: .retryable,
            branchID: branch.id,
            operationID: NovelOperationID(),
            payloadSHA256: "0000000000000000000000000000000000000000000000000000000000000",
            baseCheckpointID: branch.headCheckpointID,
            baseHeadRevision: branch.headRevision,
            candidateID: nil,
            collectionTarget: nil,
            selectedText: "A collected paragraph awaiting legacy extraction.",
            proposedChapterVersion: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_800_100),
            lastError: "上一次收集提取失败"
        )
        var seededDocument = try await harness.repository.loadProject(id: harness.projectID).document
        seededDocument.pendingOperations.append(collectionPending)
        harness.workspace.projectSnapshot = NovelProjectSnapshot(loaded: NovelLoadedProject(
            document: seededDocument,
            access: .readWrite
        ))

        await harness.session.retryPending(collectionPendingID)

        XCTAssertNil(harness.workspace.stateSyncActivity)
        // Give any (incorrectly) started polling task a chance to publish before asserting again.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(harness.workspace.stateSyncActivity)
    }

    /// Automatic background sync may already be publishing progress when the user taps retry.
    /// The single-owner mechanism (`stateSyncActivityOwnerID` gated behind `operationOwnerID`)
    /// must reject the concurrent manual retry rather than let it reset or clear the activity
    /// that automatic sync owns.
    func testConcurrentSessionRetryDoesNotStompAutomaticStateSyncOwnership() async throws {
        let fixture = try persistedManualSync(status: .pending)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .pause,
                .complete,
            ])]
        )

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()

        let progressPublished = await eventually(timeout: 3) {
            harness.workspace.stateSyncActivity?.requestStartedAt != nil
        }
        XCTAssertTrue(progressPublished)
        let activityBeforeRetryTap = try XCTUnwrap(harness.workspace.stateSyncActivity)
        let pendingID = activityBeforeRetryTap.pendingID
        XCTAssertEqual(pendingID, fixture.pendingID)

        // The automatic sync still owns the in-flight operation, so this concurrent manual
        // retry must be rejected by `acquireSessionOperation` and must not touch the activity.
        await harness.session.retryPending(pendingID)

        XCTAssertEqual(harness.workspace.stateSyncActivity, activityBeforeRetryTap)

        let requests = await harness.adapter.requests
        let request = try XCTUnwrap(requests.first)
        await harness.adapter.resume(runID: request.runID)
        let syncCompleted = await eventually {
            let document = try? await harness.repository.loadProject(id: harness.projectID).document
            return document?.branches[0].syncStatus == .synchronized
        }
        XCTAssertTrue(syncCompleted)
        // 「仓库文档已 synchronized」不等于「内存 activity 已清理」:两者之间隔着
        // perform() 的 reload 阶段若干个 await(清理在函数级 defer 里)。直接断言
        // 会在合跑负载下偶发失败(实测 5 次复现 2 次,单跑必绿),但这是**测试判据
        // 太急**,不是产品竞态——同一用例前面的抢占断言(activity 不被踩)始终稳定。
        // 故把最终断言也包进 eventually,而不是放宽它。
        let activityCleared = await eventually { harness.workspace.stateSyncActivity == nil }
        XCTAssertTrue(activityCleared, "同步终态后 stateSyncActivity 应被清理")
    }

    func testAutomaticManualSyncHealsTransientFailureWithoutBanner() async throws {
        let fixture = try persistedManualSync(status: .pending)
        let transient = NovelModelFailure(
            code: "transient_sync_failure",
            message: "状态同步暂时失败。",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.fail(transient)]),
                NovelModelScript(steps: [.delta(validRebuildJSON), .complete]),
            ]
        )
        let branchID = try XCTUnwrap(harness.workspace.selectedBranchID)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let recovered = await eventually(timeout: 5) {
            let project = try? await harness.repository.loadProject(id: harness.projectID).document
            return project?.branches[0].syncStatus == .synchronized
        }
        XCTAssertTrue(recovered)
        XCTAssertNil(harness.workspace.automaticStateSyncFailureMessage(
            projectID: harness.projectID,
            branchID: branchID
        ))
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testAutomaticManualSyncUsesOneModelRebuild() async throws {
        let fixture = try persistedManualSync(status: .pending)
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta(validRebuildJSON),
                .complete,
            ])]
        )
        let branchID = try XCTUnwrap(harness.workspace.selectedBranchID)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let recovered = await eventually(timeout: 5) {
            let project = try? await harness.repository.loadProject(id: harness.projectID).document
            return project?.pendingOperations.isEmpty == true &&
                project?.branches[0].syncStatus == .synchronized
        }
        XCTAssertTrue(recovered)
        XCTAssertNil(harness.workspace.automaticStateSyncFailureMessage(
            projectID: harness.projectID,
            branchID: branchID
        ))
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(harness.workspace.projectSnapshot?.pendingOperations.first?.lastError)
    }

    func testChapterRevisionApprovalRelinksLatestChapterWithoutFollowUpSync() async throws {
        let fixture = try documentWithChapter(
            content: "第一段。\n\n第二段有矛盾。\n\n第三段。"
        )
        let prompt = NovelAskUserPrompt(
            question: "将第 1 章《第一章》第 2 段写入正文？",
            options: NovelChapterRevisionApproval.options,
            chapterRevision: NovelChapterRevisionProposal(
                chapterID: fixture.chapterID,
                chapterOrdinal: 1,
                chapterTitle: "第一章",
                startParagraph: 2,
                endParagraph: 2,
                oldText: "第二段有矛盾。",
                newText: "第二段已经改掉了那个矛盾。",
                reason: "事实自相矛盾"
            )
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .askUser(prompt, preface: "这段和前面的设定对不上。"),
            ])]
        )
        harness.session.mode = .discussPlan
        let didStart = await harness.session.send(text: "请改第二段")
        XCTAssertTrue(didStart)
        let didAsk = await eventually {
            !harness.session.isRunning &&
                harness.session.durableMessages.last?.interaction == .askUser(prompt)
        }
        XCTAssertTrue(didAsk)
        let promptMessage = try XCTUnwrap(harness.session.durableMessages.last)
        let messageCountBefore = harness.session.durableMessages.count

        // Contract v1.1 D-B: approving the revision commits the chapter and
        // its deterministic plot module atomically; no separate sync run exists.
        let didAnswer = await harness.session.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: NovelChapterRevisionApproval.approveOption
        )
        XCTAssertTrue(didAnswer)
        XCTAssertFalse(
            harness.workspace.canCancelAutomaticStateSync(
                projectID: harness.projectID,
                branchID: harness.workspace.selectedBranchID ?? fixture.document.branches[0].id
            ),
            "原子提交没有后续同步，不应出现停止按钮"
        )
        let synced = await eventually(timeout: 5) {
            harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized &&
                !harness.workspace.isPerforming &&
                !harness.session.isRunning
        }
        XCTAssertTrue(synced, harness.workspace.errorMessage ?? "写入正文后剧情同步未完成")

        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(
            persisted.chapterVersions.last?.content,
            "第一段。\n\n第二段已经改掉了那个矛盾。\n\n第三段。"
        )
        XCTAssertEqual(persisted.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(persisted.pendingOperations.isEmpty)
        XCTAssertEqual(persisted.checkpoints.last?.kind, .manualSync)
        let response = NovelAskUserResponse(
            promptMessageID: promptMessage.id,
            answer: NovelChapterRevisionApproval.approveOption
        )
        XCTAssertEqual(persisted.sessions[0].messages.last?.interaction, .askUserAnswer(response))
        let coldSession = NovelSessionViewModel(workspace: harness.workspace)
        await coldSession.bindToCurrentSelection()
        let coldList = try XCTUnwrap(coldSession.projectedListModel(
            project: XCTUnwrap(harness.workspace.projectSnapshot),
            branch: XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertEqual(coldList.rows.first { $0.id == promptMessage.id }?.askUser?.response, response)
        let answeredAgain = await coldSession.answerAskUser(
            promptMessageID: promptMessage.id,
            answer: NovelChapterRevisionApproval.approveOption
        )
        XCTAssertFalse(answeredAgain)
        let afterRepeat = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(afterRepeat, persisted)
        XCTAssertEqual(coldSession.durableMessages.count, messageCountBefore + 1)
        XCTAssertFalse(harness.session.isRunning)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFailedChapterRevisionApprovalDoesNotPersistBodyOrAnswer() async throws {
        let fixture = try documentWithChapter(content: "原正文。")
        let promptID = NovelMessageID()
        let prompt = NovelAskUserPrompt(
            question: "批准修改？",
            options: NovelChapterRevisionApproval.options,
            chapterRevision: NovelChapterRevisionProposal(
                chapterID: fixture.chapterID, chapterOrdinal: 1, chapterTitle: "第一章",
                startParagraph: 1, endParagraph: 1, oldText: "原正文。", newText: "修改后的正文。", reason: nil
            )
        )
        var document = fixture.document
        document.sessions[0].messages.append(NovelSessionMessageRecord(
            id: promptID, sequence: 0, role: .assistant, mode: .discussPlan, kind: .discussion,
            content: "批准修改？", createdAt: document.project.updatedAt,
            runID: nil, candidateID: nil, interaction: .askUser(prompt)
        ))
        document.sessions[0].revision += 1
        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(repository: repository, document: document, scripts: [])
        await repository.failNextCommits(1)
        let failed = await harness.session.answerAskUser(
            promptMessageID: promptID, answer: NovelChapterRevisionApproval.approveOption
        )
        XCTAssertFalse(failed)
        let afterFailure = try await repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(afterFailure, document)
        let list = try XCTUnwrap(harness.session.projectedListModel(
            project: XCTUnwrap(harness.workspace.projectSnapshot),
            branch: XCTUnwrap(harness.workspace.branchSnapshot)
        ))
        XCTAssertNil(list.rows.first { $0.id == promptID }?.askUser?.response)
        let retried = await harness.session.answerAskUser(
            promptMessageID: promptID, answer: NovelChapterRevisionApproval.approveOption
        )
        XCTAssertTrue(retried)
        let saved = try await repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(saved.chapterVersions.last?.content, "修改后的正文。")
        XCTAssertEqual(saved.sessions[0].messages.last?.interaction, .askUserAnswer(NovelAskUserResponse(
            promptMessageID: promptID, answer: NovelChapterRevisionApproval.approveOption
        )))
    }

    func testChapterRevisionApprovalPublishesSubmittingStateUntilCommitCompletes() async throws {
        let fixture = try documentWithChapter(
            content: "第一段。\n\n第二段有矛盾。\n\n第三段。"
        )
        let promptMessageID = NovelMessageID()
        let prompt = NovelAskUserPrompt(
            question: "将第 1 章《第一章》第 2 段写入正文？",
            options: NovelChapterRevisionApproval.options,
            chapterRevision: NovelChapterRevisionProposal(
                chapterID: fixture.chapterID,
                chapterOrdinal: 1,
                chapterTitle: "第一章",
                startParagraph: 2,
                endParagraph: 2,
                oldText: "第二段有矛盾。",
                newText: "第二段已经改掉了那个矛盾。",
                reason: "事实自相矛盾"
            )
        )
        var document = fixture.document
        document.sessions[0].messages = [
            NovelSessionMessageRecord(
                id: promptMessageID,
                sequence: 0,
                role: .assistant,
                mode: .discussPlan,
                kind: .discussion,
                content: "这段和前面的设定对不上。",
                createdAt: document.project.updatedAt,
                runID: nil,
                candidateID: nil,
                interaction: .askUser(prompt)
            )
        ]
        document.sessions[0].revision = 1
        try NovelDocumentValidator.validate(document)

        let repository = NovelSessionFailingRepository()
        let harness = try await makeHarness(
            repository: repository,
            document: document,
            scripts: []
        )
        await repository.blockNextCommit()

        let answerTask = Task { @MainActor in
            await harness.session.answerAskUser(
                promptMessageID: promptMessageID,
                answer: NovelChapterRevisionApproval.approveOption
            )
        }
        let submitting = await eventually {
            await repository.commitIsBlocked() &&
                harness.session.answeringAskUserMessageID == promptMessageID
        }
        XCTAssertTrue(submitting)
        XCTAssertTrue(harness.session.isBusy)

        await repository.resumeBlockedCommit()
        let didAnswer = await answerTask.value
        XCTAssertTrue(didAnswer)
        XCTAssertNil(harness.session.answeringAskUserMessageID)
        let saved = try await repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(saved.sessions[0].messages.last?.interaction, .askUserAnswer(NovelAskUserResponse(
            promptMessageID: promptMessageID,
            answer: NovelChapterRevisionApproval.approveOption
        )))
    }

    func testAutomaticManualSyncDoesNotOuterRetryValidationFailures() async throws {
        let fixture = try persistedManualSync(status: .pending)
        let truncated = #"{"schemaVersion":1,"stateSummary":"Mara entered"#
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: Array(
                repeating: NovelModelScript(steps: [.delta(truncated), .complete]),
                count: 3
            )
        )
        let branchID = try XCTUnwrap(harness.workspace.selectedBranchID)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let failed = await eventually(timeout: 5) {
            harness.workspace.automaticStateSyncFailureMessage(
                projectID: harness.projectID,
                branchID: branchID
            ) != nil && !harness.workspace.isPerforming
        }
        XCTAssertTrue(failed)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, 3)
        let persisted = try await harness.repository.loadProject(id: harness.projectID).document
        XCTAssertEqual(persisted.branches[0].syncStatus, .needsSync)
        XCTAssertEqual(persisted.pendingOperations.first?.status, .retryable)
    }

    func testAutomaticSyncFailureRetryResumesRetryablePendingOnFirstTap() async throws {
        let fixture = try persistedManualSync(status: .pending)
        let failure = NovelModelFailure(
            code: "structured_no_output_timeout",
            message: "状态同步请求超时，请稍后重试。",
            isRetryable: true
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: Array(
                repeating: NovelModelScript(steps: [.fail(failure)]),
                count: NovelGhostwriteHeal.defaultMaxInfraRetries
            ) + [
                NovelModelScript(steps: [.delta(validRebuildJSON), .complete]),
            ]
        )
        let branchID = try XCTUnwrap(harness.workspace.selectedBranchID)

        harness.workspace.scheduleAutomaticStateSyncIfNeeded()
        let failed = await eventually(timeout: 5) {
            harness.workspace.automaticStateSyncFailureMessage(
                projectID: harness.projectID,
                branchID: branchID
            ) != nil &&
                harness.workspace.projectSnapshot?.pendingOperations.first?.status == .retryable
        }
        XCTAssertTrue(failed)

        harness.workspace.retryAutomaticStateSync(
            projectID: harness.projectID,
            branchID: branchID
        )
        let recovered = await eventually(timeout: 5) {
            harness.workspace.projectSnapshot?.pendingOperations.isEmpty == true &&
                harness.workspace.branchSnapshot?.branch.syncStatus == .synchronized
        }
        XCTAssertTrue(recovered)
        let requests = await harness.adapter.requests
        XCTAssertEqual(requests.count, NovelGhostwriteHeal.defaultMaxInfraRetries + 1)
    }

}
