import XCTest
@testable import iosApp

@MainActor
final class NovelCreationWorkspaceMutationTests: NovelCreationViewModelTestCase {
    func testCreateMaterialAndReloadThroughDeepInterface() async throws {
        let repository = InMemoryNovelProjectRepository()
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )

        let projectID = await viewModel.createProject(
            name: "潮汐城",
            mode: .blank
        )
        let createdID = try XCTUnwrap(projectID)
        await viewModel.saveMaterial(
            materialID: nil,
            kind: .world,
            title: "潮汐法则",
            content: "每次退潮都会暴露一条旧街。",
            tags: ["潮汐", "城市"],
            injectionMode: .always
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, createdID)
        XCTAssertEqual(viewModel.activeMaterials.count, 1)

        let restarted = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await restarted.loadProjects(selecting: createdID)

        XCTAssertEqual(restarted.projectSnapshot?.materials.count, 1)
        XCTAssertEqual(restarted.projectSnapshot?.materialRevisions.first?.title, "潮汐法则")
        XCTAssertEqual(restarted.projectSnapshot?.materialRevisions.first?.injectionMode, .always)
    }

    func testModelPolicyAndMaterialDeletionReloadFromRepository() async throws {
        let repository = InMemoryNovelProjectRepository()
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let createdProjectID = await viewModel.createProject(name: "星港", mode: .blank)
        let projectID = try XCTUnwrap(createdProjectID)
        await viewModel.saveMaterial(
            materialID: nil,
            kind: .character,
            title: "林澈",
            content: "修理废弃导航仪。",
            tags: [],
            injectionMode: .smart
        )
        let materialID = try XCTUnwrap(viewModel.activeMaterials.first?.id)

        let savedModelPolicy = await viewModel.setModelPolicy(
            .fixed(providerID: "provider-1", modelID: "model-1")
        )
        XCTAssertTrue(savedModelPolicy)
        await viewModel.deleteMaterial(materialID)

        let loaded = try await repository.loadProject(id: projectID)
        XCTAssertEqual(
            loaded.document.project.modelPolicy,
            .fixed(providerID: "provider-1", modelID: "model-1")
        )
        XCTAssertTrue(try XCTUnwrap(loaded.document.materials.first).isDeleted)
        XCTAssertFalse(loaded.document.materialRevisions.isEmpty)
        XCTAssertTrue(viewModel.activeMaterials.isEmpty)
    }

    func testSetModelPolicyReportsFailureWithoutSelectedProject() async {
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: InMemoryNovelProjectRepository())
        )

        let saved = await viewModel.setModelPolicy(
            .fixed(providerID: "provider-1", modelID: "model-1")
        )

        XCTAssertFalse(saved)
    }

    func testFailedInjectionPreviewDoesNotReuseThePreviousResult() async throws {
        let repository = InMemoryNovelProjectRepository()
        let adapter = ScriptedNovelModelAdapter(resolvedModel: NovelResolvedModel(
            providerID: "provider",
            ownerProviderID: "provider",
            modelID: "model",
            wireModelID: "model",
            displayName: "Model",
            contextWindowTokens: 32_000
        ))
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository, modelRunner: adapter)
        )
        let createdProjectID = await viewModel.createProject(name: "预览", mode: .blank)
        let projectID = try XCTUnwrap(createdProjectID)
        let branchID = try XCTUnwrap(viewModel.selectedBranchID)

        func request(inputBudgetTokens: Int) -> NovelInjectionPreviewRequest {
            NovelInjectionPreviewRequest(
                projectID: projectID,
                branchID: branchID,
                kind: .discussion,
                mode: .discussPlan,
                granularity: nil,
                userText: "讨论下一步",
                sourceChapterVersionID: nil,
                injectionOverrides: .none,
                inputBudgetTokens: inputBudgetTokens
            )
        }

        let first = await viewModel.previewInjection(request(inputBudgetTokens: 8_000))
        XCTAssertNotNil(first)
        XCTAssertEqual(viewModel.injectionPreview, first)

        let failed = await viewModel.previewInjection(request(inputBudgetTokens: 0))
        XCTAssertNil(failed)
        XCTAssertNil(viewModel.injectionPreview)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testBranchActionsUseCurrentRevisionAndSelectFork() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.documentWithForkableCheckpoint()
        _ = try await repository.createProject(document)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects(selecting: document.project.id)

        let createdBranchID = await viewModel.forkBranch(
            from: document.branches[0].id,
            checkpointID: document.branches[0].headCheckpointID,
            name: "另一种潮汐"
        )

        let forkID = try XCTUnwrap(viewModel.selectedBranchID)
        XCTAssertEqual(createdBranchID, forkID)
        XCTAssertNotEqual(forkID, document.branches[0].id)
        XCTAssertEqual(viewModel.activeBranches.count, 2)
        await viewModel.renameBranch(forkID, name: "红月线")
        await viewModel.setMainBranch(forkID)

        XCTAssertEqual(viewModel.projectSnapshot?.project.mainBranchID, forkID)
        XCTAssertEqual(
            viewModel.projectSnapshot?.branches.first(where: { $0.id == forkID })?.name,
            "红月线"
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    func testPackageExportDeleteAndImportRestoresSemanticSnapshot() async throws {
        let repository = InMemoryNovelProjectRepository()
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        let createdProjectID = await viewModel.createProject(name: "纸灯", mode: .blank)
        let projectID = try XCTUnwrap(createdProjectID)
        await viewModel.saveMaterial(
            materialID: nil,
            kind: .masterOutline,
            title: "主线",
            content: "一个守灯人寻找熄灭的太阳。",
            tags: [],
            injectionMode: .always
        )
        let before = try await repository.loadProject(id: projectID)
        let exportedArtifact = await viewModel.exportProjectPackage()
        let artifact = try XCTUnwrap(exportedArtifact)

        await viewModel.deleteProject()
        let afterDeletion = try await repository.listProjects()
        XCTAssertTrue(afterDeletion.isEmpty)
        let importResult = await viewModel.importProject(artifact.data, choice: .reject)

        let restored = try await repository.loadProject(id: projectID)
        XCTAssertEqual(importResult, .selected(projectID))
        XCTAssertEqual(restored.document, before.document)
        XCTAssertEqual(viewModel.selectedProjectID, projectID)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testUnavailableProjectDeletesFromItsSummaryWithoutLoading() async throws {
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        // createProject writes a sharded package; corrupt its actual primary
        // layout rather than an unused legacy monofile beside it.
        let primaryURL = NovelProjectShardedStorage.layoutURL(in:
            NovelProjectShardedStorage.packageDirectory(
                projectDirectory: root.appendingPathComponent("projects", isDirectory: true),
                projectID: document.project.id
            )
        )
        try Data("corrupt".utf8).write(to: primaryURL, options: [.atomic])
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects()
        let unavailable = try XCTUnwrap(viewModel.projects.first)
        XCTAssertNotNil(unavailable.loadError)
        XCTAssertNil(viewModel.projectSnapshot)

        await viewModel.deleteProject(unavailable)

        XCTAssertTrue(viewModel.projects.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        let remainingProjects = try await repository.listProjects()
        XCTAssertTrue(remainingProjects.isEmpty)
    }

    func testImportPreviewStillOffersKeepBothWhenTheLocalProjectIsUnreadable() async throws {
        let root = try NovelTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = NovelFileProjectRepository(rootDirectory: root)
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let package = try NovelProjectPackageCodec.encode(document)
        let primaryURL = NovelProjectShardedStorage.layoutURL(in:
            NovelProjectShardedStorage.packageDirectory(
                projectDirectory: root.appendingPathComponent("projects", isDirectory: true),
                projectID: document.project.id
            )
        )
        try Data("corrupt".utf8).write(to: primaryURL, options: [.atomic])
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )

        let preview = await viewModel.previewImport(package.data)

        XCTAssertEqual(preview?.sourceProjectID, document.project.id)
        XCTAssertNotNil(preview?.existingProject?.loadError)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCommittedDeleteRemovesTheRowEvenWhenTheFollowingListReloadFails() async throws {
        let repository = InMemoryNovelProjectRepository()
        let document = try NovelTestFixtures.document()
        _ = try await repository.createProject(document)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: creation)
        await viewModel.loadProjects(selecting: document.project.id)
        let summary = try XCTUnwrap(viewModel.projects.first)
        await creation.failNextProjectListSnapshots(1)

        await viewModel.deleteProject(summary)

        XCTAssertTrue(viewModel.projects.isEmpty)
        let storedProjects = try await repository.listProjects()
        XCTAssertTrue(storedProjects.isEmpty)
        XCTAssertNotNil(viewModel.projectListLoadError)
    }

    func testKeepBothImportSelectsRemappedProjectWithoutReplacingSource() async throws {
        let repository = InMemoryNovelProjectRepository()
        let source = try NovelTestFixtures.document()
        _ = try await repository.createProject(source)
        let artifact = try NovelProjectPackageCodec.encode(source)
        let viewModel = NovelCreationViewModel(
            creation: DefaultNovelCreation(repository: repository)
        )
        await viewModel.loadProjects(selecting: source.project.id)

        let importResult = await viewModel.importProject(artifact.data, choice: .keepBoth)

        let selectedID = try XCTUnwrap(viewModel.selectedProjectID)
        XCTAssertEqual(importResult, .selected(selectedID))
        XCTAssertNotEqual(selectedID, source.project.id)
        let projects = try await repository.listProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(viewModel.projectSnapshot?.project.id, selectedID)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testImportUsesTheAcceptedPreviewWithoutPreparingItAgain() async throws {
        let repository = InMemoryNovelProjectRepository()
        let source = try NovelTestFixtures.document()
        let artifact = try NovelProjectPackageCodec.encode(source)
        let creation = SnapshotFailureNovelCreation(
            base: DefaultNovelCreation(repository: repository)
        )
        let viewModel = NovelCreationViewModel(creation: creation)
        let preparedPreview = await viewModel.previewImport(artifact.data)
        let preview = try XCTUnwrap(preparedPreview)

        let result = await viewModel.importProject(
            artifact.data,
            choice: .reject,
            preview: preview
        )

        XCTAssertEqual(result, .selected(source.project.id))
        let previewSnapshotCount = await creation.projectImportPreviewSnapshotCount
        XCTAssertEqual(previewSnapshotCount, 1)
    }

    func testReplaceImportRefreshesPreviewAfterStoppingADurableRun() async throws {
        let repository = InMemoryNovelProjectRepository()
        let source = try NovelTestFixtures.document()
        _ = try await repository.createProject(source)
        let package = try NovelProjectPackageCodec.encode(source)
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
        let viewModel = NovelCreationViewModel(creation: creation)
        let didSelect = await viewModel.selectProject(source.project.id)
        XCTAssertTrue(didSelect)
        let initialPreview = await viewModel.previewImport(package.data)
        XCTAssertEqual(initialPreview?.existingProject?.revision, source.project.revision)
        let branch = try XCTUnwrap(source.branches.first)
        let request = NovelRunRequest(
            id: NovelRunID(),
            operationID: NovelOperationID(),
            projectID: source.project.id,
            branchID: branch.id,
            kind: .discussion,
            mode: .discussPlan,
            granularity: nil,
            userText: "停止后替换",
            userMessageID: NovelMessageID(),
            assistantMessageID: NovelMessageID(),
            candidateID: nil,
            generationReceiptID: NovelReceiptID(),
            injectionReceiptID: NovelReceiptID(),
            sourceChapterVersionID: nil,
            inputBudgetTokens: 16_000,
            expectedProjectRevision: source.project.revision,
            expectedConfigRevision: source.project.configRevision,
            expectedBranchHeadRevision: branch.headRevision
        )
        _ = try await creation.start(request)

        let stopped = await viewModel.stopActiveRunsForProjectOperation(
            projectID: source.project.id
        )
        XCTAssertTrue(stopped)
        let refreshedPreview = await viewModel.previewImport(package.data)
        let acceptedPreview = try XCTUnwrap(refreshedPreview)
        XCTAssertGreaterThan(
            acceptedPreview.existingProject?.revision ?? 0,
            initialPreview?.existingProject?.revision ?? 0
        )

        let result = await viewModel.importProject(
            package.data,
            choice: .replace,
            preview: acceptedPreview
        )

        XCTAssertEqual(result, .selected(source.project.id))
        let stored = try await repository.loadProject(id: source.project.id)
        XCTAssertEqual(stored.document, source)
    }

}
