import XCTest
@testable import iosApp

@MainActor
final class NovelCreationSyncAndRecoveryTests: NovelCreationViewModelTestCase {
    func testAutomaticStateSyncSnapshotFailureHealsWithoutBanner() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let sourceVersion = try XCTUnwrap(fixture.document.chapterVersions.first {
            $0.id == fixture.versionID
        })
        let edited = try NovelReducer.apply(
            .saveManualEdit(NovelSaveManualEditCommand(
                context: NovelMutationContext(
                    operationID: NovelOperationID(),
                    expectedProjectRevision: fixture.document.project.revision,
                    expectedConfigRevision: fixture.document.project.configRevision,
                    expectedBranchHeadRevision: branch.headRevision
                ),
                projectID: fixture.document.project.id,
                branchID: branch.id,
                chapterID: sourceVersion.chapterID,
                versionID: NovelChapterVersionID(),
                title: sourceVersion.title,
                content: sourceVersion.content + "\n\n等待同步。",
                factCompatibilityID: UUID(),
                expectedWorkingRevision: branch.workingRevision
            )),
            to: fixture.document
        ).document
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(edited)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            ),
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let base = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let creation = SnapshotFailureNovelCreation(base: base)
        let viewModel = NovelCreationViewModel(creation: creation)
        let didSelect = await viewModel.selectProject(edited.project.id)
        XCTAssertTrue(didSelect)
        await creation.failNextProjectSnapshots(1)

        viewModel.scheduleAutomaticStateSync(
            projectID: edited.project.id,
            branchID: branch.id
        )
        let recovered = await eventually(timeout: 5) {
            let requests = await adapter.requests
            return !requests.isEmpty
        }
        XCTAssertTrue(recovered)
        XCTAssertTrue(viewModel.canCancelAutomaticStateSync(
            projectID: edited.project.id,
            branchID: branch.id
        ))
        XCTAssertNil(viewModel.automaticStateSyncFailureMessage(
            projectID: edited.project.id,
            branchID: branch.id
        ))
        // Auto-sync failures must not raise the global "无法完成操作" alert.
        XCTAssertNil(viewModel.errorMessage)
        viewModel.cancelAutomaticStateSync(
            projectID: edited.project.id,
            branchID: branch.id
        )
    }

    func testBranchSelectionRefreshesDurableRunBeforeRequestingConfirmation() async throws {
        let repository = InMemoryNovelProjectRepository()
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            ),
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let creation = DefaultNovelCreation(repository: repository, modelRunner: adapter)
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(creation: creation)
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let sourceBranchID = try XCTUnwrap(viewModel.selectedBranchID)
        let createdBranchID = await viewModel.forkBranch(
            from: sourceBranchID,
            checkpointID: document.branches[0].headCheckpointID,
            name: "另一路径"
        )
        let destinationBranchID = try XCTUnwrap(createdBranchID)
        await viewModel.selectBranch(sourceBranchID)
        let project = try await repository.loadProject(id: document.project.id).document
        let source = try XCTUnwrap(project.branches.first { $0.id == sourceBranchID })
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: project.project.id,
            branchID: sourceBranchID,
            kind: .discussion,
            mode: .discussPlan,
            granularity: nil,
            userText: "先生成，再切分支。",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: nil,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            inputBudgetTokens: 16_000,
            expectedProjectRevision: project.project.revision,
            expectedConfigRevision: project.project.configRevision,
            expectedBranchHeadRevision: source.headRevision
        )
        _ = try await creation.start(request)
        let becameDurable = await eventually {
            let loaded = try? await repository.loadProject(id: project.project.id).document
            return loaded?.activeRuns.contains(where: {
                $0.id == request.id && $0.status == .running
            }) == true
        }
        XCTAssertTrue(becameDurable)
        XCTAssertNil(viewModel.branchSnapshot?.branch.activeRunID)

        let preflight = await viewModel.selectBranch(
            destinationBranchID,
            stoppingActiveRun: false
        )

        XCTAssertEqual(preflight, .requiresStoppingActiveRun)
        XCTAssertEqual(viewModel.selectedBranchID, sourceBranchID)
        XCTAssertEqual(viewModel.branchSnapshot?.branch.activeRunID, request.id)

        let selected = await viewModel.selectBranch(
            destinationBranchID,
            stoppingActiveRun: true
        )
        XCTAssertEqual(selected, .selected)
        XCTAssertEqual(viewModel.selectedBranchID, destinationBranchID)
        let final = try await repository.loadProject(id: project.project.id).document
        XCTAssertEqual(final.activeRuns.first(where: { $0.id == request.id })?.status, .interrupted)
    }

    func testAutomaticStateSyncRetryUsesDurablePendingWhenFailureReloadAlsoFails() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let sourceVersion = try XCTUnwrap(fixture.document.chapterVersions.first {
            $0.id == fixture.versionID
        })
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: fixture.document.project.revision,
                expectedConfigRevision: fixture.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branch.id,
            chapterID: sourceVersion.chapterID,
            versionID: NovelChapterVersionID(),
            title: sourceVersion.title,
            content: sourceVersion.content + "\n\n等待同步。",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let document = try NovelReducer.apply(.saveManualEdit(edit), to: fixture.document).document
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let failure = NovelModelFailure(
            code: "state_sync_timeout",
            message: "状态同步请求超时，请稍后重试。",
            isRetryable: true
        )
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            ),
            scripts: [
                NovelModelScript(steps: [.pause, .fail(failure)]),
                NovelModelScript(steps: [.pause]),
            ]
        )
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let viewModel = NovelCreationViewModel(creation: creation)
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)

        viewModel.scheduleAutomaticStateSync(projectID: document.project.id, branchID: branch.id)
        let firstRequestStarted = await eventually {
            await adapter.requests.count == 1
        }
        XCTAssertTrue(firstRequestStarted)
        await creation.failNextProjectSnapshots(1)
        let firstRequests = await adapter.requests
        let firstRequest = try XCTUnwrap(firstRequests.first)
        await adapter.resume(runID: firstRequest.runID)

        let secondRequestStarted = await eventually(timeout: 5) {
            await adapter.requests.count == 2
        }
        XCTAssertTrue(secondRequestStarted)
        viewModel.cancelAutomaticStateSync(projectID: document.project.id, branchID: branch.id)
    }

    func testAutomaticStateSyncCancellationIsScopedAndPublishesItsTerminalState() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let sourceVersion = try XCTUnwrap(fixture.document.chapterVersions.first {
            $0.id == fixture.versionID
        })
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: fixture.document.project.revision,
                expectedConfigRevision: fixture.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branch.id,
            chapterID: sourceVersion.chapterID,
            versionID: NovelChapterVersionID(),
            title: sourceVersion.title,
            content: sourceVersion.content + "\n\n等待同步。",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let document = try NovelReducer.apply(
            .saveManualEdit(edit),
            to: fixture.document
        ).document
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            ),
            scripts: [NovelModelScript(steps: [.pause])]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        let branchID = try XCTUnwrap(document.branches.first?.id)
        viewModel.scheduleAutomaticStateSync(
            projectID: document.project.id,
            branchID: branchID
        )

        let otherBranchID = NovelBranchID()
        XCTAssertTrue(viewModel.canCancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: branchID
        ))
        XCTAssertFalse(viewModel.canCancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: otherBranchID
        ))
        viewModel.cancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: otherBranchID
        )
        XCTAssertTrue(viewModel.isProjectSelectionBlocked)
        let requestStarted = await eventually {
            let requests = await adapter.requests
            return !requests.isEmpty
        }
        XCTAssertTrue(requestStarted)
        let stateSyncLeaseID = BackgroundGenerationKeepAlive.shared.activeLeaseIds.first(where: {
            $0.hasPrefix("novel-state-sync-")
        })
        XCTAssertNotNil(stateSyncLeaseID)
        let cancelledAfterWrongTarget = await adapter.cancelledRunIDs
        XCTAssertTrue(cancelledAfterWrongTarget.isEmpty)

        viewModel.cancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: branchID
        )
        // Immediately after Stop the UI should show stopping rather than vanish.
        XCTAssertTrue(viewModel.isStateSyncStopping(
            projectID: document.project.id,
            branchID: branchID
        ))
        XCTAssertEqual(
            viewModel.stateSyncStatusTitle(
                projectID: document.project.id,
                branchID: branchID
            ),
            "正在停止剧情同步"
        )
        let cancelled = await eventually {
            let cancelledRunIDs = await adapter.cancelledRunIDs
            return !cancelledRunIDs.isEmpty &&
                !viewModel.isProjectSelectionBlocked &&
                !viewModel.isStateSyncStopping(
                    projectID: document.project.id,
                    branchID: branchID
                )
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(viewModel.canCancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: branchID
        ))
        if let stateSyncLeaseID {
            XCTAssertFalse(BackgroundGenerationKeepAlive.shared.holdsLease(stateSyncLeaseID))
        }
    }

    func testManualStateSyncRetryCanRestartAfterCancel() async throws {
        let fixture = try documentWithChapter()
        let branch = fixture.document.branches[0]
        let sourceVersion = try XCTUnwrap(fixture.document.chapterVersions.first {
            $0.id == fixture.versionID
        })
        let edit = NovelSaveManualEditCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: fixture.document.project.revision,
                expectedConfigRevision: fixture.document.project.configRevision,
                expectedBranchHeadRevision: branch.headRevision
            ),
            projectID: fixture.document.project.id,
            branchID: branch.id,
            chapterID: sourceVersion.chapterID,
            versionID: NovelChapterVersionID(),
            title: sourceVersion.title,
            content: sourceVersion.content + "\n\n等待同步。",
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.workingRevision
        )
        let document = try NovelReducer.apply(
            .saveManualEdit(edit),
            to: fixture.document
        ).document
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(document)
        let failure = NovelModelFailure(
            code: "state_sync_timeout",
            message: "状态同步请求超时，请稍后重试。",
            isRetryable: true
        )
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            ),
            scripts: Array(
                repeating: NovelModelScript(steps: [.fail(failure)]),
                count: NovelGhostwriteHeal.defaultMaxInfraRetries
            ) + [
                NovelModelScript(steps: [.pause]),
                NovelModelScript(steps: [.pause]),
            ]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)

        viewModel.scheduleAutomaticStateSync(
            projectID: document.project.id,
            branchID: branch.id
        )
        let becameRetryable = await eventually(timeout: 5) {
            viewModel.projectSnapshot?.pendingOperations.contains(where: {
                $0.kind == .manualSync && $0.status == .retryable
            }) == true && !viewModel.isProjectSelectionBlocked
        }
        XCTAssertTrue(becameRetryable)
        let pendingID = try XCTUnwrap(
            viewModel.projectSnapshot?.pendingOperations.first(where: {
                $0.kind == .manualSync && $0.status == .retryable
            })?.id
        )
        let autoAttempts = await adapter.requests.count
        XCTAssertEqual(autoAttempts, NovelGhostwriteHeal.defaultMaxInfraRetries)

        let firstRetry = viewModel.startManualStateSyncRetry(pendingID)
        XCTAssertNotNil(firstRetry)
        let firstRetryStarted = await eventually {
            await adapter.requests.count == autoAttempts + 1
        }
        XCTAssertTrue(firstRetryStarted)

        viewModel.cancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: branch.id
        )
        let fullyStopped = await eventually {
            !viewModel.isProjectSelectionBlocked &&
                !viewModel.isStateSyncStopping(
                    projectID: document.project.id,
                    branchID: branch.id
                )
        }
        XCTAssertTrue(fullyStopped)

        // Reload so a cancel-marked retryable pending is visible for the second start.
        await viewModel.loadProjects(selecting: document.project.id)
        let retryableAgain = await eventually {
            viewModel.projectSnapshot?.pendingOperations.contains(where: {
                $0.id == pendingID && $0.status == .retryable
            }) == true
        }
        XCTAssertTrue(retryableAgain)

        let secondRetry = viewModel.startManualStateSyncRetry(pendingID)
        XCTAssertNotNil(
            secondRetry,
            "Cancel must not orphan manualStateSyncTask and block later retries."
        )
        let secondRetryStarted = await eventually(timeout: 3) {
            await adapter.requests.count == autoAttempts + 2
        }
        XCTAssertTrue(secondRetryStarted)
        viewModel.cancelAutomaticStateSync(
            projectID: document.project.id,
            branchID: branch.id
        )
    }

    func testReplaceImportUsesPreviewRevisionAndRestoresPackage() async throws {
        let repository = InMemoryNovelProjectRepository()
        let source = try NovelTestFixtures.document()
        _ = try await repository.createProject(source)
        let artifact = try NovelProjectPackageCodec.encode(source)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects(selecting: source.project.id)
        await viewModel.renameProject("本地改名")
        XCTAssertEqual(viewModel.projectSnapshot?.project.name, "本地改名")

        await viewModel.importProject(artifact.data, choice: .replace)

        let replaced = try await repository.loadProject(id: source.project.id).document
        XCTAssertEqual(replaced, source)
        XCTAssertEqual(viewModel.projectSnapshot?.project.name, source.project.name)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRestoreChapterVersionThroughViewModelCreatesNewHeadVersion() async throws {
        let repository = InMemoryNovelProjectRepository()
        let fixture = try documentWithChapter()
        _ = try await repository.createProject(fixture.document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects(selecting: fixture.document.project.id)
        await viewModel.restoreChapterVersion(fixture.versionID)

        let restored = try await repository.loadProject(id: fixture.document.project.id).document
        let currentVersionID = try XCTUnwrap(restored.branches[0].workingChapterSelections.first?.versionID)
        let currentVersion = try XCTUnwrap(restored.chapterVersions.first { $0.id == currentVersionID })
        XCTAssertNotEqual(currentVersionID, fixture.versionID)
        XCTAssertEqual(currentVersion.kind, .restore)
        XCTAssertEqual(currentVersion.sourceChapterVersionID, fixture.versionID)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testIncompatibleHistoricalVersionBecomesManualRewriteWithAtomicPlotCommit() async throws {
        var fixture = try documentWithChapter()
        let currentVersion = try XCTUnwrap(fixture.document.chapterVersions.first(where: {
            $0.id == fixture.versionID
        }))
        let historical = NovelChapterVersionRecord(
            id: NovelChapterVersionID(),
            chapterID: currentVersion.chapterID,
            kind: .collected,
            title: "另一条第一章",
            content: "列车没有停靠，主角也没有登车。",
            factCompatibilityID: UUID(),
            sourceChapterVersionID: currentVersion.id,
            sourceCandidateID: nil,
            createdAt: currentVersion.createdAt.addingTimeInterval(60),
            operationID: fixture.document.appliedOperations[0].operationID
        )
        fixture.document.chapterVersions.append(historical)
        try NovelDocumentValidator.validate(fixture.document)
        let repository = InMemoryNovelProjectRepository()
        _ = try await repository.createProject(fixture.document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects(selecting: fixture.document.project.id)

        let saved = await viewModel.saveManualRewrite(from: historical)
        XCTAssertTrue(saved)

        let edited = try await repository.loadProject(id: fixture.document.project.id).document
        let branch = edited.branches[0]
        let selectedID = try XCTUnwrap(branch.workingChapterSelections.first?.versionID)
        let selected = try XCTUnwrap(edited.chapterVersions.first(where: { $0.id == selectedID }))
        XCTAssertEqual(selected.kind, .manualEdit)
        XCTAssertEqual(selected.title, historical.title)
        XCTAssertEqual(selected.content, historical.content)
        XCTAssertNotEqual(selected.factCompatibilityID, historical.factCompatibilityID)
        // Contract D-B: the manual rewrite and deterministic plot module are
        // one commit; this latest-chapter edit does not need a model sync run.
        XCTAssertEqual(branch.syncStatus, .synchronized)
        XCTAssertNotEqual(branch.headCheckpointID, fixture.document.branches[0].headCheckpointID)
        XCTAssertEqual(branch.headRevision, fixture.document.branches[0].headRevision + 1)
        XCTAssertEqual(edited.stateSnapshots.count, fixture.document.stateSnapshots.count + 1)
        XCTAssertEqual(Array(edited.stateSnapshots.dropLast()), fixture.document.stateSnapshots)
        let checkpoint = try XCTUnwrap(edited.checkpoints.first { $0.id == branch.headCheckpointID })
        XCTAssertEqual(checkpoint.kind, .manualSync)
        XCTAssertEqual(checkpoint.chapterSelections, branch.workingChapterSelections)
        let plot = try XCTUnwrap(edited.stateSnapshots.first { $0.id == branch.currentStateSnapshotID })
        let module = try XCTUnwrap(plot.chapterPlots.first { $0.chapterID == selected.chapterID })
        XCTAssertTrue(module.text.contains(historical.content))
        XCTAssertFalse(module.stale)
        XCTAssertTrue(edited.pendingOperations.isEmpty)
        XCTAssertEqual(edited.factAttempts, fixture.document.factAttempts)
        XCTAssertEqual(edited.generationReceipts, fixture.document.generationReceipts)
        XCTAssertNil(viewModel.automaticStateSyncFailureMessage(
            projectID: edited.project.id,
            branchID: branch.id
        ))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.projectSnapshot?.pendingOperations.isEmpty == true)
    }

    private func documentWithChapter() throws -> (
        document: NovelProjectDocumentV1,
        versionID: NovelChapterVersionID
    ) {
        var document = try NovelTestFixtures.documentWithForkableCheckpoint()
        let branch = document.branches[0]
        let chapterID = NovelChapterID()
        let versionID = NovelChapterVersionID()
        let operationID = document.appliedOperations[0].operationID
        document.chapters.append(NovelChapterRecord(
            id: chapterID,
            createdAt: document.project.updatedAt
        ))
        document.chapterVersions.append(NovelChapterVersionRecord(
            id: versionID,
            chapterID: chapterID,
            kind: .collected,
            title: "第一章",
            content: "雾从停靠两次的终点站涌来。",
            factCompatibilityID: UUID(),
            sourceCandidateID: nil,
            createdAt: document.project.updatedAt,
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
        return (document, versionID)
    }

    /// 接线契约：agent 写工具经 executor 直接 perform（绕过 VM 的 perform wrapper）后，
    /// 领域 mutation 广播必须驱动 VM 自动刷新——否则项目列表/顶栏/面板要等 run
    /// 终态甚至重进才更新（R1/R2 修复的回归锁）。
    func testExternalMutationBroadcastRefreshesProjectList() async throws {
        let creation = DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        let projectID = NovelProjectID()
        let branchID = NovelBranchID()
        _ = try await creation.perform(.createProject(NovelTestFixtures.createCommand(
            projectID: projectID,
            branchID: branchID,
            name: "旧名"
        )))
        let viewModel = NovelCreationViewModel(creation: creation)
        await viewModel.loadProjects(restoresSelection: false)
        XCTAssertEqual(viewModel.projects.first(where: { $0.id == projectID })?.name, "旧名")

        // executor 同款路径：不经过 VM wrapper 的直接 perform。
        guard case .project(let snapshot) = try await creation.snapshot(.project(projectID)) else {
            XCTFail("Expected a project snapshot")
            return
        }
        _ = try await creation.perform(.renameProject(NovelRenameProjectCommand(
            context: NovelMutationContext(
                operationID: NovelOperationID(),
                expectedProjectRevision: snapshot.project.revision,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: projectID,
            name: "agent 改的名"
        )))

        let refreshed = await eventually {
            viewModel.projects.first(where: { $0.id == projectID })?.name == "agent 改的名"
        }
        XCTAssertTrue(refreshed, "mutation 广播后项目列表未自动刷新：\(viewModel.projects.map(\.name))")
    }

}
