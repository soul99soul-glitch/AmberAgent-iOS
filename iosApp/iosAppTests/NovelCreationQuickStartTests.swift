import XCTest
@testable import iosApp

@MainActor
final class NovelCreationQuickStartTests: NovelCreationViewModelTestCase {
    func testQuickStartAndBranchOverrideUseRealModuleActions() async throws {
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
            scripts: [NovelModelScript(steps: [
                .delta(quickStartSuggestionsJSON),
                .complete
            ])]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let createdID = await viewModel.createProject(
            name: "雾海列车",
            mode: .quickStart,
            genre: "奇幻悬疑",
            coreIdea: "一列火车只在失去记忆的人面前出现。"
        )
        let projectID = try XCTUnwrap(createdID)
        let suggestionsReady = await eventually {
            viewModel.projectSnapshot?.settingProposals.count == 4 &&
                viewModel.quickStartStatus == .idle
        }
        XCTAssertTrue(suggestionsReady)
        let modelRequests = await adapter.requests
        XCTAssertEqual(modelRequests.map(\.purpose), [.quickStart])
        XCTAssertTrue(viewModel.activeMaterials.isEmpty)
        let proposal = try XCTUnwrap(viewModel.projectSnapshot?.settingProposals.first(where: {
            if case .some(.quickStart(_, .world)) = $0.origin { return true }
            return false
        }))
        await viewModel.resolveProposal(
            proposal.id,
            resolution: .accept(
                materialID: NovelMaterialID(),
                revisionID: NovelMaterialRevisionID(),
                kind: .world,
                title: proposal.title,
                content: proposal.content,
                tags: ["列车"],
                injectionMode: .smart,
                aliases: []
            )
        )
        let material = try XCTUnwrap(viewModel.activeMaterials.first)
        let globalRevisionID = material.currentRevisionID

        await viewModel.setBranchMaterialOverride(
            materialID: material.id,
            change: .createRevision(
                revisionID: NovelMaterialRevisionID(),
                title: "雾海规则 · 主线",
                content: "这条主线里，终点站允许第二次停靠。",
                tags: ["主线"],
                injectionMode: .always
            )
        )

        let loaded = try await repository.loadProject(id: projectID).document
        XCTAssertEqual(loaded.project.creationMode, .quickStart)
        XCTAssertEqual(loaded.project.quickStartSeed?.genre, "奇幻悬疑")
        XCTAssertEqual(loaded.materials[0].currentRevisionID, globalRevisionID)
        XCTAssertEqual(loaded.branches[0].overrideRevisionIDs.count, 1)
        XCTAssertNotEqual(loaded.branches[0].overrideRevisionIDs[0], globalRevisionID)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testQuickStartWithoutSuggestionsRehydratesARealRetryStateAfterRestart() async throws {
        let repository = InMemoryNovelProjectRepository()
        let first = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let createdID = await first.createProject(
            name: "未完成的开场",
            mode: .quickStart,
            genre: "悬疑",
            coreIdea: "一封信会忘记自己的收件人。"
        )
        let projectID = try XCTUnwrap(createdID)
        for _ in 0..<100 where first.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(first.errorMessage)

        let restarted = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await restarted.loadProjects(selecting: projectID)

        guard case .failed = restarted.quickStartStatus else {
            return XCTFail("A quick-start project without proposals must offer regeneration.")
        }
    }

    func testLateQuickStartBackgroundCallbackDoesNotCancelTheCurrentRun() async throws {
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
            scripts: [
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
                NovelModelScript(steps: [.pause])
            ]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let createdProjectID = await viewModel.createProject(
            name: "雾海列车",
            mode: .quickStart,
            genre: "奇幻悬疑",
            coreIdea: "一列火车只在失去记忆的人面前出现。"
        )
        let projectID = try XCTUnwrap(createdProjectID)

        let firstRunFinished = await eventually {
            viewModel.projectSnapshot?.settingProposals.count == 4 &&
                viewModel.quickStartStatus == .idle
        }
        XCTAssertTrue(firstRunFinished)
        let firstRequests = await adapter.requests
        let firstRunID = try XCTUnwrap(firstRequests.first?.runID)

        let startedRunID = await viewModel.startQuickStartSuggestions(guidance: "换一套设定")
        let currentRunID = try XCTUnwrap(startedRunID)
        let currentRunStarted = await eventually {
            (await adapter.requests).count == 2 &&
                viewModel.quickStartStatus == .generating(runID: currentRunID)
        }
        XCTAssertTrue(currentRunStarted)

        await viewModel.interruptSessionForBackground(
            projectID: projectID,
            runID: firstRunID,
            deadline: Date()
        )

        XCTAssertEqual(viewModel.quickStartStatus, .generating(runID: currentRunID))
        let cancelledRunIDs = await adapter.cancelledRunIDs
        XCTAssertFalse(cancelledRunIDs.contains(currentRunID))

        // 收掉本测试刻意暂停的当前 run，避免把全局后台租约带进后续用例。
        await viewModel.interruptSessionForBackground(
            projectID: projectID,
            runID: currentRunID,
            deadline: Date().addingTimeInterval(2)
        )
    }

    func testQuickStartCanBeRegeneratedWithGuidanceAfterAllProposalsAreRejected() async throws {
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
            scripts: [
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete])
            ]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let createdID = await viewModel.createProject(
            name: "雾海列车",
            mode: .quickStart,
            genre: "奇幻悬疑",
            coreIdea: "一列火车只在失去记忆的人面前出现。"
        )
        let projectID = try XCTUnwrap(createdID)
        for _ in 0..<100 where viewModel.projectSnapshot?.settingProposals.count != 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.projectSnapshot?.settingProposals.count, 4)

        // 模拟用户全部拒绝：逐一 reject，卡片列表应清空。
        let firstRoundProposals = viewModel.projectSnapshot?.settingProposals ?? []
        for proposal in firstRoundProposals {
            await viewModel.resolveProposal(proposal.id, resolution: .reject)
        }
        XCTAssertEqual(viewModel.branchSnapshot?.activeSettingProposals.count, 0)

        let secondStartedRunID = await viewModel.startQuickStartSuggestions(guidance: "主角别那么悲惨")
        let secondRunID = try XCTUnwrap(secondStartedRunID)

        for _ in 0..<100 where (viewModel.projectSnapshot?.settingProposals.count ?? 0) <= firstRoundProposals.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.projectSnapshot?.settingProposals.count, 8)

        let requests = await adapter.requests
        let regenerationRequest = try XCTUnwrap(requests.last { $0.runID == secondRunID })
        let regenerationText = regenerationRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(
            regenerationText.contains("主角别那么悲惨"),
            "The regeneration run must carry the user's guidance in its request text."
        )
        XCTAssertNil(viewModel.errorMessage)
        _ = projectID
    }

    func testRejectActiveSettingProposalsClearsEveryPendingCard() async throws {
        let repository = InMemoryNovelProjectRepository()
        var document = try NovelTestFixtures.document()
        let now = document.project.updatedAt
        var ids: [NovelProposalID] = []
        for title in ["边境王朝", "宗门誓约", "殿前司"] {
            let id = NovelProposalID()
            ids.append(id)
            document.settingProposals.append(NovelSettingProposalRecord(
                id: id,
                branchID: document.branches[0].id,
                title: title,
                content: "\(title) 的说明。",
                createdAt: now,
                isResolved: false
            ))
        }
        let source = document.stateSnapshots[0]
        document.stateSnapshots[0] = NovelStateSnapshotRecord(
            id: source.id,
            eventIDs: source.eventIDs,
            summary: source.summary,
            branchOutline: source.branchOutline,
            unresolvedEntityNames: source.unresolvedEntityNames,
            createdAt: source.createdAt,
            settingProposalIDs: ids
        )
        try NovelDocumentValidator.validate(document)
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let didSelect = await viewModel.selectProject(document.project.id)
        XCTAssertTrue(didSelect)
        XCTAssertEqual(viewModel.branchSnapshot?.activeSettingProposals.count, 3)

        let ok = await viewModel.rejectActiveSettingProposals()
        XCTAssertTrue(ok)
        XCTAssertEqual(viewModel.branchSnapshot?.activeSettingProposals.count, 0)
        XCTAssertEqual(viewModel.projectSnapshot?.settingProposals.filter(\.isResolved).count, 3)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testQuickStartRegenerationUsesEditedCoreIdeaForCurrentRunWithoutMutatingSeed() async throws {
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
            scripts: [
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete])
            ]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let originalCoreIdea = "一列火车只在失去记忆的人面前出现。"
        let editedCoreIdea =
            "一列火车只在主动舍弃记忆的人面前出现，主角必须找回被自己删除的名字。"
        let createdID = await viewModel.createProject(
            name: "雾海列车",
            mode: .quickStart,
            genre: "奇幻悬疑",
            coreIdea: originalCoreIdea
        )
        let projectID = try XCTUnwrap(createdID)
        for _ in 0..<100 where viewModel.branchSnapshot?.activeSettingProposals.count != 4 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let regeneratedRunID = await viewModel.startQuickStartSuggestions(
            coreIdeaOverride: editedCoreIdea
        )
        let runID = try XCTUnwrap(regeneratedRunID)
        for _ in 0..<100 where (viewModel.projectSnapshot?.settingProposals.count ?? 0) != 8 {
            try await Task.sleep(for: .milliseconds(10))
        }

        var requests = await adapter.requests
        for _ in 0..<100 where !requests.contains(where: { $0.runID == runID }) {
            try await Task.sleep(for: .milliseconds(10))
            requests = await adapter.requests
        }
        let regenerationRequest = try XCTUnwrap(requests.last { $0.runID == runID })
        let regenerationText = regenerationRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(regenerationText.contains("本轮核心想法（仅本次有效）"))
        XCTAssertTrue(regenerationText.contains(editedCoreIdea))
        XCTAssertTrue(regenerationText.contains("以本轮内容为准"))

        let loaded = try await repository.loadProject(id: projectID).document
        XCTAssertEqual(loaded.project.quickStartSeed?.coreIdea, originalCoreIdea)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testQuickStartRegenerationSupersedesCurrentProposalsOnlyAfterSuccess() async throws {
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
            scripts: [
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
                NovelModelScript(steps: [.delta(quickStartSuggestionsJSON), .complete]),
            ]
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let projectID = await viewModel.createProject(
            name: "雾海列车",
            mode: .quickStart,
            genre: "奇幻悬疑",
            coreIdea: "一列火车只在失去记忆的人面前出现。"
        )
        XCTAssertNotNil(projectID)
        for _ in 0..<100 where viewModel.branchSnapshot?.activeSettingProposals.count != 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstProposalIDs = Set(
            viewModel.branchSnapshot?.activeSettingProposals.map(\.id) ?? []
        )

        let regeneratedRunID = await viewModel.startQuickStartSuggestions(guidance: "换一套设定")
        XCTAssertNotNil(regeneratedRunID)
        for _ in 0..<100 where viewModel.projectSnapshot?.settingProposals.count != 8 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await adapter.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(viewModel.branchSnapshot?.activeSettingProposals.count, 4)
        XCTAssertTrue(viewModel.projectSnapshot?.settingProposals
            .filter { firstProposalIDs.contains($0.id) }
            .allSatisfy { $0.supersededByRunID == regeneratedRunID } == true)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testQuickStartFailureRecoveryIsScopedToItsOwningBranch() async throws {
        let repository = InMemoryNovelProjectRepository()
        let projectID = NovelProjectID()
        let sourceBranchID = NovelBranchID()
        let createOperationID = NovelOperationID()
        var document = try NovelReducer.createProject(NovelCreateProjectCommand(
            context: NovelMutationContext(
                operationID: createOperationID,
                expectedProjectRevision: nil,
                expectedConfigRevision: nil,
                expectedBranchHeadRevision: nil
            ),
            projectID: projectID,
            branchID: sourceBranchID,
            sessionID: NovelSessionID(),
            initialStateSnapshotID: NovelStateSnapshotID(),
            initialCheckpointID: NovelCheckpointID(),
            name: "雾海列车",
            branchName: "主线",
            creationMode: .quickStart,
            quickStartSeed: NovelQuickStartSeed(
                genre: "悬疑",
                coreIdea: "一列没有终点的火车。"
            )
        )).document
        let root = document.branches[0]
        let checkpoint = NovelBranchCheckpointRecord(
            id: NovelCheckpointID(),
            kind: .manualSync,
            createdOnBranchID: root.id,
            parentCheckpointID: root.headCheckpointID,
            chapterSelections: [],
            stateSnapshotID: root.currentStateSnapshotID,
            sessionCursor: .empty,
            branchOverrideRevisionIDs: [],
            sourceCandidateID: nil,
            baseHeadRevision: 0,
            operationID: createOperationID,
            createdAt: document.project.updatedAt
        )
        document.checkpoints.append(checkpoint)
        document.branches[0].headCheckpointID = checkpoint.id
        document.branches[0].headRevision = 1
        try NovelDocumentValidator.validate(document)
        _ = try await repository.createProject(document)
        let adapter = ScriptedNovelModelAdapter(
            resolvedModel: NovelResolvedModel(
                providerID: "provider",
                ownerProviderID: "provider",
                modelID: "model",
                wireModelID: "model-wire",
                displayName: "Model",
                contextWindowTokens: 32_000
            )
        )
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let didSelectProject = await viewModel.selectProject(projectID)
        XCTAssertTrue(didSelectProject)
        let createdBranchID = await viewModel.forkBranch(
            from: sourceBranchID,
            checkpointID: checkpoint.id,
            name: "平行线"
        )
        let forkID = try XCTUnwrap(createdBranchID)
        await viewModel.selectBranch(sourceBranchID)

        let failedRunID = await viewModel.startQuickStartSuggestions(guidance: "换一套设定")
        XCTAssertNotNil(failedRunID)
        let failed = await eventually {
            guard case .failed = viewModel.quickStartStatus else { return false }
            return !viewModel.isPerforming
        }
        XCTAssertTrue(failed)
        guard case .failed(let sourceFailure) = viewModel.quickStartStatus else {
            return XCTFail("The source branch must retain its transient failure.")
        }
        await viewModel.selectBranch(forkID)

        XCTAssertEqual(viewModel.selectedBranchID, forkID)
        XCTAssertEqual(
            viewModel.quickStartStatus,
            .failed(message: "尚未生成创作建议，可以重新生成。")
        )

        await viewModel.selectBranch(sourceBranchID)
        XCTAssertEqual(viewModel.quickStartStatus, .failed(message: sourceFailure))
    }

}
