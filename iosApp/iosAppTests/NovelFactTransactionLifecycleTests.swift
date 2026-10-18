import CryptoKit
import XCTest
@testable import iosApp

final class NovelFactTransactionLifecycleTests: XCTestCase {
    func testGhostwriteAdjudicationRejectsWrongPlanIdentityAtomically() throws {
        let fixture = try ghostwriteAdjudicationCandidateDocument()
        let before = fixture.document
        var command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        command.source = .systemAutoCollect
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: try command.canonicalPayloadSHA256(),
            in: before
        )
        let artifacts = try NovelTestFixtures.factTransactionArtifacts(
            document: prepared.document,
            pendingID: command.pendingID
        )
        let plan = try XCTUnwrap(
            fixture.document.confirmedChapterPlan(for: command.branchID)
        )

        XCTAssertThrowsError(try NovelFactTransactionReducer.commitGhostwriteAdjudication(
            command,
            payloadSHA256: try command.canonicalPayloadSHA256(),
            planID: NovelChapterPlanID(),
            planDigest: plan.contentDigest,
            delta: try NovelStructuredOutputDecoder.decodeStateDelta(
                from: validDeltaJSON()
            ),
            artifacts: artifacts,
            in: fixture.document
        )) { error in
            guard let error = error as? NovelError,
                  case .invalidInput = error else {
                return XCTFail("Expected a plan-identity rejection, got \(error)")
            }
        }
        XCTAssertEqual(before, fixture.document)
        XCTAssertEqual(before.candidates[0].status, .available)
        XCTAssertEqual(
            before.confirmedChapterPlan(for: command.branchID)?.id,
            plan.id
        )
    }

    func testGhostwriteAdjudicationCommitsAllArtifactsAndRotatesPlanOnce() throws {
        let fixture = try ghostwriteAdjudicationCandidateDocument()
        var command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        command.source = .systemAutoCollect
        let payloadSHA256 = try command.canonicalPayloadSHA256()
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: payloadSHA256,
            in: fixture.document
        )
        let artifacts = try NovelTestFixtures.factTransactionArtifacts(
            document: prepared.document,
            pendingID: command.pendingID
        )
        let plan = try XCTUnwrap(
            fixture.document.confirmedChapterPlan(for: command.branchID)
        )
        let delta = NovelStateDeltaV1(
            schemaVersion: 1,
            stateSummary: "Mara opened the archive.",
            events: [NovelStateEventV1(
                id: "archive-opened",
                kind: "discovery",
                summary: "Mara opened the archive.",
                entityReferences: ["Mara"],
                evidence: "Mara opened the archive."
            )],
            characterChanges: [],
            relationshipChanges: [],
            foreshadowingChanges: [],
            unresolvedEntityNames: ["Mara"],
            branchOutlinePatch: "Mara investigates the archive.",
            settingProposals: [NovelSettingProposalDraftV1(
                id: "bell-rule",
                title: "The bell's warning",
                content: "The bell rings twice before danger.",
                evidence: "The bell rang twice."
            )]
        )
        let nextPlanID = NovelChapterPlanID()
        let nextPlan = NovelChapterPlanProposalV1(
            outlinePlacement: "Chapter Two",
            goalAndConflict: "Mara follows the archive map.",
            mustHappen: ["Mara reaches the lower archive."],
            mustNotHappen: ["Mara leaves the city."],
            endingHook: "A second bell rings.",
            visibleFacts: ["Mara knows the archive is open."]
        )

        let committed = try NovelFactTransactionReducer.commitGhostwriteAdjudication(
            command,
            payloadSHA256: payloadSHA256,
            planID: plan.id,
            planDigest: plan.contentDigest,
            nextPlanID: nextPlanID,
            nextPlan: nextPlan,
            delta: delta,
            artifacts: artifacts,
            in: fixture.document,
            now: fixture.document.project.updatedAt.addingTimeInterval(1)
        )
        let after = committed.document

        XCTAssertEqual(after.project.revision, fixture.document.project.revision + 1)
        XCTAssertEqual(after.project.configRevision, fixture.document.project.configRevision + 1)
        XCTAssertEqual(after.chapters.count, fixture.document.chapters.count + 1)
        XCTAssertEqual(after.chapterVersions.count, fixture.document.chapterVersions.count + 1)
        XCTAssertEqual(after.events.count, fixture.document.events.count + 1)
        XCTAssertEqual(after.stateSnapshots.count, fixture.document.stateSnapshots.count + 1)
        XCTAssertEqual(after.settingProposals.count, fixture.document.settingProposals.count + 1)
        XCTAssertEqual(after.checkpoints.count, fixture.document.checkpoints.count + 1)
        XCTAssertEqual(after.injectionReceipts.count, fixture.document.injectionReceipts.count + 1)
        XCTAssertEqual(after.generationReceipts.count, fixture.document.generationReceipts.count + 1)
        XCTAssertTrue(after.pendingOperations.isEmpty)
        let rotatedPlan = try XCTUnwrap(after.confirmedChapterPlan(for: command.branchID))
        XCTAssertEqual(rotatedPlan.id, nextPlanID)
        XCTAssertEqual(rotatedPlan.mustHappen, nextPlan.mustHappen)
        XCTAssertNotEqual(rotatedPlan.id, plan.id)
        XCTAssertEqual(after.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(after.appliedOperations.count, fixture.document.appliedOperations.count + 1)
        XCTAssertEqual(after.appliedOperations.last?.kind, .collectCandidate)
        XCTAssertEqual(after.appliedOperations.last?.appliedProjectRevision, after.project.revision)

        let candidate = try XCTUnwrap(after.candidates.first { $0.id == command.candidateID })
        XCTAssertEqual(candidate.status, .collected)
        let checkpoint = try XCTUnwrap(after.checkpoints.first { $0.id == candidate.collectedCheckpointID })
        XCTAssertEqual(checkpoint.kind, .collection)
        XCTAssertEqual(checkpoint.sourceCandidateID, candidate.id)
        XCTAssertEqual(after.chapterVersions.last?.sourceCandidateID, candidate.id)
        XCTAssertEqual(checkpoint.stateSnapshotID, after.stateSnapshots.last?.id)
        XCTAssertEqual(after.events.last?.summary, "Mara opened the archive.")
        XCTAssertEqual(after.injectionReceipts.last?.factTransaction?.kind, .stateDelta)
        XCTAssertEqual(after.generationReceipts.last?.factTransaction?.kind, .stateDelta)
        XCTAssertEqual(committed.outcome, .candidateCollected(
            projectID: fixture.document.project.id,
            branchID: command.branchID,
            candidateID: command.candidateID,
            checkpointID: checkpoint.id,
            chapterVersionID: after.chapterVersions.last!.id,
            revision: after.project.revision
        ))
    }

    func testCollectionCommitsImmediatelyWithoutStartingFactModel() async throws {
        // 续写/新章：host 写 plot/ 快进，不再抽 JSON。
        let fixture = try candidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])]
        )
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )

        guard case .candidateCollected = try await harness.creation.perform(
            .collectCandidate(command)
        ) else {
            return XCTFail("Expected collection outcome")
        }

        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(final.candidates[0].status, .collected)
        XCTAssertEqual(final.chapterVersions.last?.content, fixture.candidate.content)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(
            final.stateSnapshots.last?.recentWrittenHighlights.contains(where: {
                $0.contains("Chapter One")
            }) == true
        )
        let requests = await harness.adapter.requests
        XCTAssertFalse(
            requests.contains { $0.purpose == .stateRebuild },
            "collection must not start a JSON rebuild"
        )
    }

    func testFastForwardCollectWritesDeterministicPlotPointerWithoutModel() async throws {
        let fixture = try candidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [
                .delta("""
                # 本章
                - Mara opened the archive
                - The bell rang twice

                # 当前
                Mara has opened the archive; the bell still echoes.
                """),
                .complete,
            ])]
        )
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )

        guard case .candidateCollected = try await harness.creation.perform(
            .collectCandidate(command)
        ) else {
            return XCTFail("Expected collection outcome")
        }

        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        let baseSnapshotID = fixture.document.branches[0].currentStateSnapshotID
        let baseSummary = fixture.document.stateSnapshots.first {
            $0.id == baseSnapshotID
        }?.summary
        XCTAssertEqual(final.stateSnapshots.last?.summary, baseSummary)
        XCTAssertTrue(
            final.stateSnapshots.last?.chapterPlots.last?.text.contains("Mara opened the archive") == true
        )
        XCTAssertEqual(final.stateSnapshots.last?.chapterPlots.last?.stale, false)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSystemAutoCollectUsesInlineStateDeltaAndStaysSynchronized() async throws {
        let fixture = try autoCollectableCandidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])]
        )
        var command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        command.source = .systemAutoCollect

        guard case .candidateCollected = try await harness.creation.perform(
            .collectCandidate(command)
        ) else {
            return XCTFail("Expected collection outcome")
        }

        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(final.candidates[0].status, .collected)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(final.stateSnapshots.count, fixture.document.stateSnapshots.count + 1)
        let requests = await harness.adapter.requests
        XCTAssertFalse(requests.contains { $0.purpose == .stateRebuild })
    }

    func testSystemAutoCollectFallsBackToWithoutStateSyncWhenDeltaFails() async throws {
        let fixture = try autoCollectableCandidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.delta("not-valid-json"), .complete])]
        )
        var command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        command.source = .systemAutoCollect

        guard case .candidateCollected = try await harness.creation.perform(
            .collectCandidate(command)
        ) else {
            return XCTFail("Expected fallback collection outcome")
        }

        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(final.candidates[0].status, .collected)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        let requests = await harness.adapter.requests
        XCTAssertFalse(
            requests.contains { $0.purpose == .stateRebuild },
            "续写快进不再尝试 JSON 重建"
        )
    }

    func testDeferredSyncRebuildsAnImmediatelyCollectedChapter() async throws {
        // 续写收录已改为 host 写 plot/，不再进入 timeout→rebuild。
        var fixture = try candidateDocument()
        fixture.document.project.modelPolicy = .fixed(
            providerID: "creative-provider",
            modelID: "creative-model"
        )
        fixture.document.project.stateSyncModelPolicy = .fixed(
            providerID: "sync-provider",
            modelID: "sync-model"
        )
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.pause]),
                NovelModelScript(steps: [.delta(validArchiveRebuildJSON()), .complete]),
            ],
            factRequestTimeout: 0.15
        )
        let collect = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        _ = try await harness.creation.perform(.collectCandidate(collect))
        let collected = try await harness.repository.document(collect.projectID)
        XCTAssertEqual(collected.branches[0].syncStatus, .synchronized)
        let collectRequests = await harness.adapter.requests
        XCTAssertTrue(factSyncRequests(in: collectRequests).isEmpty)
    }

    func testManualSyncRepairsTruncatedJSONUsingPreviousOutput() async throws {
        let fixture = try candidateDocument()
        let truncated = #"{"schemaVersion":1,"stateSummary":"Mara entered"#
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
                NovelModelScript(steps: [.delta(truncated), .complete]),
                NovelModelScript(steps: [.delta(validArchiveRebuildJSON()), .complete]),
            ]
        )
        try await collectThenSync(edited: edited, harness: harness)

        let final = try await harness.repository.document(fixture.document.project.id)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        let requests = factSyncRequests(in: await harness.adapter.requests)
        XCTAssertEqual(requests.count, 3)
        let repairUser = requests[2].messages
            .filter { $0.role == .user }
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertTrue(repairUser.contains("PREVIOUS OUTPUT"))
        XCTAssertTrue(repairUser.contains(truncated))
        XCTAssertTrue(repairUser.contains("FAILURE"))
    }

    func testManualSyncRepairsUnmatchedEvidenceUsingDecodedJSON() async throws {
        let fixture = try candidateDocument()
        let invented = """
        {
          "schemaVersion": 1,
          "stateSummary": "Someone invented a dragon.",
          "branchOutline": "A dragon appears.",
          "events": [{
            "id": "dragon",
            "kind": "discovery",
            "summary": "A dragon appeared.",
            "entityReferences": [],
            "evidence": "A dragon burst through the ceiling tiles."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": [],
          "settingProposals": []
        }
        """
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
                NovelModelScript(steps: [.delta(invented), .complete]),
                NovelModelScript(steps: [.delta(validArchiveRebuildJSON()), .complete]),
            ]
        )
        try await collectThenSync(edited: edited, harness: harness)

        let final = try await harness.repository.document(fixture.document.project.id)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        let requests = factSyncRequests(in: await harness.adapter.requests)
        XCTAssertEqual(requests.count, 3)
        let repairUser = requests[2].messages
            .filter { $0.role == .user }
            .map(\.content)
            .joined(separator: "\n")
        XCTAssertTrue(repairUser.contains("PREVIOUS OUTPUT"))
        XCTAssertTrue(repairUser.contains("dragon"))
        XCTAssertTrue(
            repairUser.contains("证据") || repairUser.contains("evidence") ||
                repairUser.contains("对不上")
        )
        XCTAssertTrue(
            repairUser.contains("A dragon burst through the ceiling tiles."),
            "repair must name the unmatched evidence sentence"
        )
    }

    func testManualSyncAcceptsEmptyFactsAfterUnmatchedRepairsAreExhausted() async throws {
        let fixture = try candidateDocument()
        let invented = """
        {
          "schemaVersion": 1,
          "stateSummary": "Someone invented a dragon.",
          "branchOutline": "A dragon appears.",
          "events": [{
            "id": "dragon",
            "kind": "discovery",
            "summary": "A dragon appeared.",
            "entityReferences": [],
            "evidence": "A dragon burst through the ceiling tiles."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": [],
          "settingProposals": []
        }
        """
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
                NovelModelScript(steps: [.delta(invented), .complete]),
                NovelModelScript(steps: [.delta(invented), .complete]),
                NovelModelScript(steps: [.delta(invented), .complete]),
            ]
        )
        try await collectThenSync(edited: edited, harness: harness)

        let final = try await harness.repository.document(fixture.document.project.id)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        let requests = await harness.adapter.requests
        XCTAssertEqual(factSyncRequests(in: requests).count, 3)
        XCTAssertFalse(
            final.events.contains(where: { $0.summary.contains("dragon") })
        )
    }

    func testUserCollectRepairsUnmatchedDeltaThenStaysSynchronized() async throws {
        let fixture = try candidateDocument()
        let invented = """
        {
          "schemaVersion": 1,
          "stateSummary": "Someone invented a dragon.",
          "events": [{
            "id": "dragon",
            "kind": "discovery",
            "summary": "A dragon appeared.",
            "entityReferences": [],
            "evidence": "A dragon burst through the ceiling tiles."
          }],
          "characterChanges": [],
          "relationshipChanges": [],
          "foreshadowingChanges": [],
          "unresolvedEntityNames": [],
          "branchOutlinePatch": "A dragon appears.",
          "settingProposals": []
        }
        """
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [
                NovelModelScript(steps: [.delta(invented), .complete]),
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
            ]
        )
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        guard case .candidateCollected = try await harness.creation.perform(
            .collectCandidate(command)
        ) else {
            return XCTFail("Expected repaired collection")
        }
        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        let requests = await harness.adapter.requests
        XCTAssertTrue(factSyncRequests(in: requests).isEmpty)
        XCTAssertFalse(
            final.stateSnapshots.last?.summary.contains("dragon") == true
        )
    }

    func testManualSyncDoesNotRepairTimeoutAfterARejectedDraft() async throws {
        let fixture = try candidateDocument()
        let invented = """
        {
          "schemaVersion": 1,
          "stateSummary": "Someone invented a dragon.",
          "branchOutline": "A dragon appears.",
          "events": [{
            "id": "dragon",
            "kind": "discovery",
            "summary": "A dragon appeared.",
            "entityReferences": [],
            "evidence": "A dragon burst through the ceiling tiles."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": [],
          "settingProposals": []
        }
        """
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
                NovelModelScript(steps: [.delta(invented), .complete]),
                NovelModelScript(steps: [.pause]),
            ],
            factRequestTimeout: 0.15
        )
        let branch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: edited.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.workingRevision
        )
        do {
            _ = try await harness.creation.perform(.syncManualEdits(sync))
            XCTFail("Timeout after a rejected draft must not succeed")
        } catch let failure as NovelStructuredModelExecutionFailure {
            XCTAssertEqual(failure.failure.code, "structured_no_output_timeout")
        }
        let requests = factSyncRequests(in: await harness.adapter.requests)
        XCTAssertEqual(requests.count, 3, "timeout must not start a fourth repair call")
    }

    func testManualSyncSurvivesSlowButContinuousOutputPastTheAbsoluteFactTimeout() async throws {
        // 状态同步用「连续无输出」超时而非绝对墙钟：本用例的 provider 持续吐出增量，
        // 总耗时超过 factRequestTimeout，但任意相邻两次增量的间隔都远小于它。
        // 旧的绝对超时会在 300ms 到点无条件杀死请求；新语义应因持续有输出而成功。
        let fixture = try candidateDocument()
        let rebuild = """
        {
          "schemaVersion": 1,
          "stateSummary": "Mara entered the archive and heard the bell.",
          "branchOutline": "Mara investigates the archive.",
          "events": [{
            "id": "event-rebuilt-archive",
            "kind": "discovery",
            "summary": "Mara entered the archive.",
            "entityReferences": ["Mara"],
            "evidence": "Mara opened the archive."
          }, {
            "id": "event-bell",
            "kind": "discovery",
            "summary": "The bell rang.",
            "entityReferences": ["Mara"],
            "evidence": "The bell rang twice."
          }],
          "characterStates": [],
          "relationships": [],
          "foreshadowing": [],
          "unresolvedEntityNames": ["Mara"],
          "settingProposals": []
        }
        """
        let quarter = rebuild.count / 4
        let first = rebuild.index(rebuild.startIndex, offsetBy: quarter)
        let second = rebuild.index(rebuild.startIndex, offsetBy: quarter * 2)
        let third = rebuild.index(rebuild.startIndex, offsetBy: quarter * 3)
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [
                    .delta(String(rebuild[..<first])),
                    .pause,
                    .delta(String(rebuild[first..<second])),
                    .pause,
                    .delta(String(rebuild[second..<third])),
                    .pause,
                    .delta(String(rebuild[third...])),
                    .complete,
                ]),
            ],
            factRequestTimeout: 0.3
        )
        let branch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: edited.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.workingRevision
        )

        let syncTask = Task {
            try await harness.creation.perform(.syncManualEdits(sync))
        }
        // The legacy fixture builds collect/edit with raw reducers, so the
        // only model request is this sync's rebuild.
        let requestStarted = await eventually {
            await harness.adapter.requests.count == 1
        }
        XCTAssertTrue(requestStarted)
        let requests = await harness.adapter.requests
        let runID = try XCTUnwrap(requests.last).runID

        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 150_000_000)
            await harness.adapter.resume(runID: runID)
        }

        guard case .manualSyncCommitted = try await syncTask.value else {
            return XCTFail("Expected slow-but-continuous output to still complete synchronization")
        }
        let final = try await harness.repository.document(edited.project.id)
        XCTAssertEqual(final.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(final.stateSnapshots.last?.summary, "Mara entered the archive and heard the bell.")
        XCTAssertTrue(final.pendingOperations.isEmpty)
    }

    func testManualSyncStillTimesOutWhenProviderProducesNoOutputAtAll() async throws {
        // 对照组：provider 完全静默挂起，证明超时保护没有被削弱——
        // 只是从「绝对墙钟」换成「连续无输出」，静默场景依然会在 noOutputTimeout 后失败。
        let fixture = try candidateDocument()
        let edited = try legacyCollectAndEditDocument(fixture: fixture)
        let harness = try await makeHarness(
            document: edited,
            scripts: [
                NovelModelScript(steps: [.delta(validDeltaJSON()), .complete]),
                NovelModelScript(steps: [.pause]),
            ],
            factRequestTimeout: 0.15
        )
        let branch = edited.branches[0]
        let sync = NovelSyncManualEditsCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: edited.project.revision,
                expectedConfigRevision: edited.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: edited.project.id,
            branchID: branch.id,
            pendingID: NovelPendingOperationID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            expectedWorkingRevision: branch.workingRevision
        )

        do {
            _ = try await harness.creation.perform(.syncManualEdits(sync))
            XCTFail("Expected a completely silent provider to still time out")
        } catch {
            // Expected: the no-output timeout still fires when there is no output at all.
        }

        let durable = try await harness.repository.document(edited.project.id)
        XCTAssertEqual(durable.pendingOperations.first?.status, .retryable)
        XCTAssertEqual(durable.branches[0].syncStatus, .needsSync)
    }

    func testProjectedManualStateSizeDoesNotGrowWithAccumulatedFactArrays() throws {
        let baseState = try XCTUnwrap(NovelTestFixtures.document().stateSnapshots.first)
        func rebuild(eventCount: Int) -> NovelStateRebuildV1 {
            NovelStateRebuildV1(
                schemaVersion: 1,
                stateSummary: "Compact summary.",
                branchOutline: "Compact outline.",
                events: (0..<eventCount).map { index in
                    NovelStateEventV1(
                        id: "event-\(index)",
                        kind: "fact",
                        summary: String(repeating: "Long historical fact. ", count: 20),
                        entityReferences: [],
                        evidence: String(repeating: "Historical evidence. ", count: 20)
                    )
                },
                characterStates: [],
                relationships: [],
                foreshadowing: [],
                unresolvedEntityNames: [],
                settingProposals: []
            )
        }

        let one = try NovelManualSyncChunker.projectedStateContext(
            baseState: baseState,
            accumulated: rebuild(eventCount: 1)
        )
        let many = try NovelManualSyncChunker.projectedStateContext(
            baseState: baseState,
            accumulated: rebuild(eventCount: 1_000)
        )

        XCTAssertLessThan(many.count - one.count, 32)
    }

    func testCollectionDoesNotDependOnModelContextWindow() async throws {
        // 2026-08-16：共创收录会打 stateDelta。5k 窗口会被注入预算判死，
        // 这不再是「收录不依赖窗口」；本例只锁正常窗口下收录当时抽完。
        let fixture = try candidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])],
            resolvedModel: NovelResolvedModel(
                providerID: "small-provider",
                ownerProviderID: "small-provider",
                modelID: "small-model",
                wireModelID: "small-wire-model",
                displayName: "Small Model",
                contextWindowTokens: 128_000
            )
        )
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )

        _ = try await harness.creation.perform(.collectCandidate(command))

        let requests = await harness.adapter.requests
        XCTAssertTrue(factSyncRequests(in: requests).isEmpty)
        let durable = try await harness.repository.document(command.projectID)
        XCTAssertEqual(durable.candidates[0].status, .collected)
        XCTAssertTrue(durable.pendingOperations.isEmpty)
        XCTAssertEqual(durable.branches[0].syncStatus, .synchronized)
    }

    func testRestartCanRetryDurablePendingWithoutTheOriginalProviderTask() async throws {
        let fixture = try candidateDocument()
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: fixture.document,
            now: Date(timeIntervalSince1970: 1_700_002_050)
        )
        let harness = try await makeHarness(
            document: prepared.document,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])]
        )
        let retry = retryCommand(
            document: prepared.document,
            pendingID: command.pendingID
        )

        guard case .candidateCollected = try await harness.creation.perform(
            .retryPending(retry)
        ) else {
            return XCTFail("Expected the restarted pending transaction to commit")
        }
        let final = try await harness.repository.document(command.projectID)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.checkpoints.count, fixture.document.checkpoints.count + 1)
        XCTAssertEqual(
            final.appliedOperations.suffix(2).map(\.kind),
            [.collectCandidate, .retryPending]
        )
        XCTAssertEqual(final.branches[0].syncStatus, .needsSync)
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLegacyCollectionRecoveryPreservesEarlierFailedAttempt() async throws {
        let fixture = try candidateDocument()
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: fixture.document
        ).document
        let retryable = try NovelFactTransactionReducer.markRetryable(
            pendingID: command.pendingID,
            message: "Initial provider failed.",
            in: prepared
        )
        let failedRetry = retryCommand(
            document: retryable,
            pendingID: command.pendingID
        )
        let withFailedAttempt = try NovelManualSyncProgressReducer.reserveRetryAttempt(
            failedRetry,
            pending: try XCTUnwrap(retryable.pendingOperations.first),
            in: retryable
        )
        let harness = try await makeHarness(
            document: withFailedAttempt,
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])]
        )
        let recovery = retryCommand(
            document: withFailedAttempt,
            pendingID: command.pendingID
        )
        guard case .candidateCollected = try await harness.creation.perform(
            .retryPending(recovery)
        ) else {
            return XCTFail("Expected legacy collection recovery to publish the prose.")
        }
        let final = try await harness.repository.document(command.projectID)
        XCTAssertEqual(
            final.factAttempts.map(\.attemptOperationID),
            [failedRetry.context.operationID]
        )
        XCTAssertTrue(final.appliedOperations.contains(where: {
            $0.operationID == failedRetry.context.operationID &&
                $0.kind == .retryPending
        }))
        let collidingRename = NovelRenameProjectCommand(
            context: NovelMutationContext(
                operationID: failedRetry.context.operationID,
                expectedProjectRevision: final.project.revision,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: final.project.id,
            name: "Conflicting Rename"
        )
        XCTAssertThrowsError(try NovelReducer.apply(
            .renameProject(collidingRename),
            to: final
        )) { error in
            guard case .idempotencyConflict(let operationID) = error as? NovelError else {
                return XCTFail("Expected idempotencyConflict, got \(error)")
            }
            XCTAssertEqual(operationID, failedRetry.context.operationID)
        }
        let requests = await harness.adapter.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNoThrow(try NovelDocumentValidator.validate(final))
    }

    func testRetryingLegacyCollectionCompletesWithoutAProviderRequest() async throws {
        let fixture = try candidateDocument()
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: fixture.document
        ).document
        let retryable = try NovelFactTransactionReducer.markRetryable(
            pendingID: command.pendingID,
            message: "Initial provider timeout.",
            in: prepared
        )
        let harness = try await makeHarness(
            document: retryable,
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let retry = retryCommand(document: retryable, pendingID: command.pendingID)
        guard case .candidateCollected = try await harness.creation.perform(.retryPending(retry)) else {
            return XCTFail("Expected the legacy collection to publish immediately.")
        }

        let durable = try await harness.repository.document(command.projectID)
        XCTAssertTrue(durable.pendingOperations.isEmpty)
        XCTAssertEqual(durable.candidates[0].status, .collected)
        XCTAssertEqual(durable.branches[0].syncStatus, .needsSync)
        let requests = await harness.adapter.requests
        let cancelledRunIDs = await harness.adapter.cancelledRunIDs
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(cancelledRunIDs.isEmpty)
    }

    func testFileRepositoryCollectionRetrySurvivesTwoActorRestarts() async throws {
        let fixture = try candidateDocument()
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let prepared = try NovelFactTransactionReducer.prepareCollection(
            command,
            payloadSHA256: command.canonicalPayloadSHA256(),
            in: fixture.document
        )
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRepository = NovelFileProjectRepository(rootDirectory: root)
        _ = try await firstRepository.createProject(fixture.document)
        _ = try await firstRepository.commitProject(
            prepared.document,
            expectedRevision: fixture.document.project.revision
        )

        let secondRepository = NovelFileProjectRepository(rootDirectory: root)
        let loadedPending = try await secondRepository.loadProject(id: command.projectID).document
        let retry = retryCommand(document: loadedPending, pendingID: command.pendingID)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "file-provider",
                ownerProviderID: "file-provider",
                modelID: "file-model",
                wireModelID: "file-wire-model",
                displayName: "File Model",
                contextWindowTokens: 128_000
            ),
            scripts: [NovelModelScript(steps: [.delta(validDeltaJSON()), .complete])]
        )
        let creation = DefaultNovelCreation(
            repository: secondRepository,
            modelRunner: adapter
        )
        _ = try await creation.perform(.retryPending(retry))

        let thirdRepository = NovelFileProjectRepository(rootDirectory: root)
        let final = try await thirdRepository.loadProject(id: command.projectID).document
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.checkpoints.filter { $0.kind == .collection }.count, 1)
        XCTAssertEqual(final.appliedOperations.filter {
            $0.operationID == command.context.operationID ||
                $0.operationID == retry.context.operationID
        }.map(\.kind), [.collectCandidate, .retryPending])
        XCTAssertEqual(Set(final.injectionReceipts.map(\.id)).count, final.injectionReceipts.count)
        XCTAssertEqual(Set(final.generationReceipts.map(\.id)).count, final.generationReceipts.count)
        XCTAssertEqual(final.branches[0].syncStatus, .needsSync)
        let requests = await adapter.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNoThrow(try NovelDocumentValidator.validate(final))
    }

    /// Contract v1.1 D-B: a fast-forward collect lands the chapter AND its
    /// plot module in ONE checkpoint — no follow-up pointer commit, no
    /// needsSync window.
    func testCollectCommitsChapterAndPlotInOneCheckpoint() async throws {
        let fixture = try candidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [plotPointerScript()]
        )
        let command = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        let checkpointsBefore = fixture.document.checkpoints.count
        _ = try await harness.creation.perform(.collectCandidate(command))

        let after = try await harness.repository.document(command.projectID)
        XCTAssertEqual(after.checkpoints.count, checkpointsBefore + 1)
        let newCheckpoint = try XCTUnwrap(after.checkpoints.last)
        XCTAssertEqual(newCheckpoint.kind, .collection)
        XCTAssertEqual(after.branches[0].syncStatus, .synchronized)
        XCTAssertEqual(after.branches[0].headCheckpointID, newCheckpoint.id)
        XCTAssertTrue(after.pendingOperations.isEmpty)
        let snapshot = try XCTUnwrap(
            after.stateSnapshots.first { $0.id == newCheckpoint.stateSnapshotID }
        )
        XCTAssertNotEqual(
            snapshot.id,
            fixture.document.branches[0].currentStateSnapshotID,
            "the merged checkpoint must carry a fresh plot snapshot"
        )
        XCTAssertTrue(snapshot.chapterPlots.contains { !$0.text.isEmpty })
    }

    /// Contract v1.1 D-B: a manual edit commits the new chapter version and
    /// the plot module it triggers in one revision step with one checkpoint.
    func testManualEditCommitsTextAndPlotInOneRevisionStep() async throws {
        let fixture = try candidateDocument()
        let harness = try await makeHarness(
            document: fixture.document,
            scripts: [plotPointerScript(), plotPointerScript()]
        )
        let collect = collectCommand(
            document: fixture.document,
            candidate: fixture.candidate
        )
        _ = try await harness.creation.perform(.collectCandidate(collect))
        let collected = try await harness.repository.document(collect.projectID)
        let branch = collected.branches[0]
        let version = try XCTUnwrap(collected.chapterVersions.last)
        let revisionBefore = collected.project.revision
        let checkpointsBefore = collected.checkpoints.count

        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: collected.project.revision,
                expectedConfigRevision: collected.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: collected.project.id,
            branchID: branch.id,
            chapterID: version.chapterID,
            versionID: NovelChapterVersionID(),
            title: version.title,
            content: version.content + "\n\nMara forced the archive door, again.",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        _ = try await harness.creation.perform(.saveManualEdit(edit))

        let after = try await harness.repository.document(collect.projectID)
        XCTAssertEqual(after.project.revision, revisionBefore + 1)
        XCTAssertEqual(after.checkpoints.count, checkpointsBefore + 1)
        let newCheckpoint = try XCTUnwrap(after.checkpoints.last)
        XCTAssertEqual(newCheckpoint.kind, .manualSync)
        XCTAssertEqual(after.branches[0].syncStatus, .synchronized)
        XCTAssertTrue(after.pendingOperations.isEmpty)
        XCTAssertEqual(
            after.branches[0].workingChapterSelections.last?.versionID,
            edit.versionID,
            "the checkpoint carries the edited selection"
        )
        let snapshot = try XCTUnwrap(
            after.stateSnapshots.first { $0.id == newCheckpoint.stateSnapshotID }
        )
        XCTAssertTrue(
            snapshot.chapterPlots.contains {
                $0.chapterID == version.chapterID && !$0.text.isEmpty
            },
            "the same checkpoint carries the relinked plot module"
        )
    }

    /// Two-chapter manuscript plus an available prose candidate — the base
    /// for D-D unresolved-plot gate tests, built through the regular fixture
    /// chain so every invariant keeps validating.
    func twoChapterDocumentWithCandidate() throws -> (
        document: NovelProjectDocumentV1,
        candidate: NovelCandidateRecord,
        firstChapterID: NovelChapterID,
        secondChapterID: NovelChapterID
    ) {
        var document = try NovelBranchTestFixtures.documentWithCollectedCandidate(
            content: "陈桥驿的风先到。"
        )
        let firstID = document.branches[0].workingChapterSelections[0].chapterID
        let secondRun = try NovelBranchTestFixtures.appendCompletedRun(
            to: document,
            branchID: document.branches[0].id,
            kind: .prose,
            content: "城门开了。"
        )
        document = try NovelBranchTestFixtures.collectCandidate(
            try XCTUnwrap(secondRun.candidateID),
            in: secondRun.document,
            title: "入汴"
        )
        let secondID = try XCTUnwrap(
            document.branches[0].workingChapterSelections.last?.chapterID
        )
        // Append (never replace) the candidate message so existing checkpoint
        // cursors and runs keep validating.
        let branch = document.branches[0]
        let candidateID = NovelCandidateID()
        let messageID = NovelMessageID()
        let message = NovelSessionMessageRecord(
            id: messageID,
            sequence: (document.sessions[0].messages.map(\.sequence).max() ?? -1) + 1,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: "下一章的候选稿。",
            createdAt: document.project.updatedAt,
            runID: nil,
            candidateID: candidateID
        )
        document.sessions[0].messages.append(message)
        document.sessions[0].revision += 1
        let candidate = NovelCandidateRecord(
            id: candidateID,
            kind: .prose,
            branchID: branch.id,
            sessionID: branch.sessionID,
            sourceMessageID: messageID,
            baseCheckpointID: branch.headCheckpointID,
            baseHeadRevision: branch.headRevision,
            status: .available,
            content: "下一章的候选稿。",
            sourceChapterVersionID: nil,
            collectedCheckpointID: nil,
            createdAt: document.project.updatedAt
        )
        document.candidates.append(candidate)
        try NovelDocumentValidator.validate(document)
        return (document, candidate, firstID, secondID)
    }

    /// Contract v1.1 D-D: after a middle-chapter edit leaves later chapters'
    /// plot modules stale, forward progress (new-chapter collect) is gated.
    /// Replacing the stale chapter itself stays open (sanctioned rewrite),
    /// and accept-as-canonical reopens the gate.
    func testUnresolvedPlotGateBlocksForwardCollectUntilResolved() throws {
        let base = try twoChapterDocumentWithCandidate()
        var document = base.document
        // Middle-chapter edit: chapter 1 module updates, chapter 2 goes stale.
        document = try NovelWorkspacePlotCommit.applyChapterModule(
            to: document,
            branchID: document.branches[0].id,
            chapterID: base.firstChapterID,
            chapterTitle: "第一章",
            chapterContent: "改写后的第一章。",
            now: Date()
        )
        XCTAssertTrue(NovelWorkspaceLedger.hasUnresolvedChapterPlots(
            branchID: document.branches[0].id,
            in: document
        ))

        // Collecting a NEW next chapter is gated.
        let collect = collectCommand(document: document, candidate: base.candidate)
        XCTAssertThrowsError(
            try NovelFactTransactionReducer.commitCollectionWithoutStateSync(
                collect,
                payloadSHA256: try NovelAction.collectCandidate(collect).canonicalPayloadSHA256(),
                in: document
            )
        ) { error in
            guard case NovelError.invalidInput(let message) = error,
                  message == NovelWorkspaceLedger.unresolvedPlotGateMessage else {
                return XCTFail("Expected unresolved-plot gate, got \(error)")
            }
        }

        // Rewriting the STALE chapter itself (replace target) stays open —
        // that is one of the sanctioned resolutions, and replacing the
        // trailing chapter also clears its stale marker. The rewrite uses a
        // fresh candidate based on the current head (real rewrites are
        // generated after the middle-chapter edit moved the head).
        let currentBranch = document.branches[0]
        let freshCandidateID = NovelCandidateID()
        let freshMessageID = NovelMessageID()
        document.sessions[0].messages.append(NovelSessionMessageRecord(
            id: freshMessageID,
            sequence: (document.sessions[0].messages.map(\.sequence).max() ?? -1) + 1,
            role: .assistant,
            mode: .writeProse,
            kind: .proseCandidate,
            content: base.candidate.content,
            createdAt: document.project.updatedAt,
            runID: nil,
            candidateID: freshCandidateID
        ))
        document.sessions[0].revision += 1
        let freshCandidate = NovelCandidateRecord(
            id: freshCandidateID,
            kind: base.candidate.kind,
            branchID: base.candidate.branchID,
            sessionID: base.candidate.sessionID,
            sourceMessageID: freshMessageID,
            baseCheckpointID: currentBranch.headCheckpointID,
            baseHeadRevision: currentBranch.headRevision,
            status: .available,
            content: base.candidate.content,
            sourceChapterVersionID: document.branches[0].workingChapterSelections
                .first(where: { $0.chapterID == base.secondChapterID })?.versionID,
            clonedFromCandidateID: nil,
            collectedCheckpointID: nil,
            createdAt: document.project.updatedAt
        )
        document.candidates.append(freshCandidate)
        let replaceCollect = NovelCollectCandidateCommand(
            context: collect.context,
            projectID: collect.projectID,
            branchID: collect.branchID,
            pendingID: NovelPendingOperationID(),
            candidateID: freshCandidate.id,
            selection: collect.selection,
            target: .replaceChapter(base.secondChapterID),
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            stateSnapshotID: NovelStateSnapshotID(),
            factCompatibilityID: UUID()
        )
        let replaced = try NovelFactTransactionReducer.commitCollectionWithPlot(
            replaceCollect,
            payloadSHA256: try NovelAction.collectCandidate(replaceCollect)
                .canonicalPayloadSHA256(),
            moduleText: nil,
            summaryOverride: nil,
            in: document,
            now: Date()
        ).document
        XCTAssertFalse(
            NovelWorkspaceLedger.hasUnresolvedChapterPlots(
                branchID: replaced.branches[0].id,
                in: replaced
            ),
            "重写过时的末章本身就是解开路径"
        )

        // Accept-as-canonical independently clears stale markers: rebuild
        // the unresolved state, then accept it.
        let restaled = try NovelWorkspacePlotCommit.applyChapterModule(
            to: replaced,
            branchID: replaced.branches[0].id,
            chapterID: base.firstChapterID,
            chapterTitle: "第一章",
            chapterContent: "再改一次第一章。",
            now: Date()
        )
        XCTAssertTrue(NovelWorkspaceLedger.hasUnresolvedChapterPlots(
            branchID: restaled.branches[0].id,
            in: restaled
        ))
        let cleared = try NovelWorkspacePlotCommit.applyAcceptStale(
            to: restaled,
            branchID: restaled.branches[0].id,
            now: Date()
        )
        XCTAssertFalse(NovelWorkspaceLedger.hasUnresolvedChapterPlots(
            branchID: cleared.branches[0].id,
            in: cleared
        ))
    }

    /// Contract v1.1 D-D: prose runs (which write forward content) refuse to
    /// start while later chapters' plot modules are unresolved.
    func testUnresolvedPlotGateBlocksProseRuns() throws {
        let base = try twoChapterDocumentWithCandidate()
        var document = base.document
        document = try NovelWorkspacePlotCommit.applyChapterModule(
            to: document,
            branchID: document.branches[0].id,
            chapterID: base.firstChapterID,
            chapterTitle: "第一章",
            chapterContent: "改写后的第一章。",
            now: Date()
        )
        let branch = document.branches[0]
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: document.project.id,
            branchID: branch.id,
            kind: .prose,
            mode: .writeProse,
            granularity: .wholeChapter,
            userText: "写下一章",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: NovelCandidateID(),
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            expectedProjectRevision: document.project.revision,
            expectedConfigRevision: document.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
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
            overrides: request.injectionOverrides,
            providerID: "gate-test",
            modelID: "gate-test",
            parameters: [:],
            createdAt: document.project.updatedAt
        )
        let generation = NovelGenerationReceiptRecord(
            id: request.generationReceiptID,
            runID: request.id,
            providerID: injection.providerID,
            modelID: injection.modelID,
            promptVersion: injection.promptVersion,
            injectionReceiptID: injection.id,
            parameters: injection.parameters,
            requestSHA256: NovelDocumentValidator.sha256(
                plan.canonicalInput + "\nMODEL REQUEST"
            ),
            createdAt: document.project.updatedAt
        )
        let artifacts = NovelGenerationStartArtifacts(
            injectionReceipt: injection,
            generationReceipt: generation
        )
        XCTAssertThrowsError(
            try NovelGenerationReducer.begin(request, artifacts: artifacts, in: document)
        ) { error in
            guard case NovelError.invalidInput(let message) = error,
                  message == NovelWorkspaceLedger.unresolvedPlotGateMessage else {
                return XCTFail("Expected unresolved-plot gate, got \(error)")
            }
        }
    }

}
