import Foundation
import Observation
import UIKit

enum NovelProjectImportChoice: Equatable, Sendable {
    case reject
    case replace
    case keepBoth
}

enum NovelProjectImportResult: Equatable, Sendable {
    case selected(NovelProjectID)
    case committedNeedsReload(NovelProjectID)
}

extension NovelCreationViewModel {
    func previewImport(_ data: Data) async -> NovelProjectImportPreview? {
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else { return nil }
        defer { releaseOperation(ownerID: ownerID) }
        do {
            guard case .projectImportPreview(let preview) = try await creation.snapshot(
                .projectImportPreview(data)
            ) else {
                throw NovelError.invalidInput("The import preview returned an unexpected snapshot.")
            }
            errorMessage = nil
            return preview
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    func importProject(
        _ data: Data,
        choice: NovelProjectImportChoice,
        preview acceptedPreview: NovelProjectImportPreview? = nil
    ) async -> NovelProjectImportResult? {
        let preview: NovelProjectImportPreview
        if let acceptedPreview {
            preview = acceptedPreview
        } else {
            guard let preparedPreview = await previewImport(data) else { return nil }
            preview = preparedPreview
        }
        let destinationID: NovelProjectID
        let policy: NovelProjectImportPolicy
        let expectedRevision: Int64?
        switch choice {
        case .reject:
            destinationID = preview.sourceProjectID
            policy = .reject
            expectedRevision = nil
        case .replace:
            guard let existing = preview.existingProject else {
                report(NovelError.invalidInput("There is no local project to replace."))
                return nil
            }
            destinationID = preview.sourceProjectID
            policy = .replace(expectedRevision: existing.revision)
            expectedRevision = existing.revision
        case .keepBoth:
            destinationID = NovelProjectID()
            policy = .keepBoth(destinationProjectID: destinationID)
            expectedRevision = nil
        }
        guard await perform(.importProject(NovelImportProjectCommand(
            context: mutationContext(projectRevision: expectedRevision),
            projectID: destinationID,
            packageData: data,
            policy: policy
        )), selecting: destinationID) else { return nil }
        if selectedProjectID == destinationID,
           projectSnapshot?.project.id == destinationID {
            return .selected(destinationID)
        }
        if reloadNoticeProjectID == destinationID {
            return .committedNeedsReload(destinationID)
        }
        return nil
    }

    func exportProjectPackage() async -> NovelProjectPackageArtifact? {
        guard let projectID = selectedProjectID else { return nil }
        do {
            guard case .package(let artifact) = try await creation.snapshot(
                .projectPackage(projectID)
            ) else {
                throw NovelError.invalidInput("The project export returned an unexpected snapshot.")
            }
            errorMessage = nil
            return artifact
        } catch {
            report(error)
            return nil
        }
    }

    func exportBranchMarkdown() async -> NovelMarkdownExportArtifact? {
        guard let projectID = selectedProjectID, let branchID = selectedBranchID else { return nil }
        do {
            guard case .markdown(let artifact) = try await creation.snapshot(
                .branchMarkdown(projectID: projectID, branchID: branchID)
            ) else {
                throw NovelError.invalidInput("The Markdown export returned an unexpected snapshot.")
            }
            errorMessage = nil
            return artifact
        } catch {
            report(error)
            return nil
        }
    }

    func applyWorkspacePlot(
        path: String,
        body: String,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> String? {
        guard let projectID = selectedProjectID, let branchID = selectedBranchID else {
            return "当前没有打开的小说项目。"
        }
        do {
            try await creation.applyWorkspacePlot(
                projectID: projectID,
                branchID: branchID,
                path: path,
                body: body,
                approvalResponse: approvalResponse
            )
            errorMessage = nil
            return nil
        } catch {
            report(error)
            return errorMessage ?? error.localizedDescription
        }
    }

    var hasStalePlot: Bool {
        branchSnapshot?.currentState.hasStaleChapterPlots == true
    }

    func materializeWorktreeDrafts() async throws {
        guard let projectID = selectedProjectID else { return }
        try await creation.materializeWorktreeDrafts(projectID: projectID)
    }

    func worktreeDraftBody(candidateID: NovelCandidateID) async -> String? {
        guard let projectID = selectedProjectID else { return nil }
        return await creation.worktreeDraftBody(
            projectID: projectID,
            candidateID: candidateID
        )
    }

    func worktreeManifestExists() async -> Bool {
        guard let projectID = selectedProjectID else { return false }
        return await creation.worktreeManifestExists(projectID: projectID)
    }

    /// 改过非末章后，后续章节的剧情记录会被标为可能过期并拦住后续写作。
    /// 所有改正文的入口都由作者确认过，因此不再要作者手动「按正文接受」：
    /// 一旦空闲就自动接受，成功后由界面弹一次轻提示。忙时跳过，
    /// 等快照更新或操作锁释放时再试。
    func scheduleStalePlotAutoSyncIfNeeded() {
        guard hasStalePlot, stalePlotAutoSyncTask == nil else { return }
        stalePlotAutoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.stalePlotAutoSyncTask = nil }
            guard self.hasStalePlot, self.canMutate, !self.isAcceptingStalePlot else { return }
            await self.acceptStalePlot()
            if !self.hasStalePlot {
                self.stalePlotAutoSyncNoticeID &+= 1
            }
        }
    }

    func acceptStalePlot() async {
        guard canMutate,
              let projectID = selectedProjectID,
              let branchID = selectedBranchID else { return }
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else { return }
        isAcceptingStalePlot = true
        defer {
            isAcceptingStalePlot = false
            releaseOperation(ownerID: ownerID)
        }
        do {
            try await creation.applyWorkspacePlotAcceptStale(
                projectID: projectID,
                branchID: branchID
            )
            errorMessage = nil
            projectSnapshot = try await project(id: projectID)
            refreshCheckoutSidecarFailure(for: projectID)
            branchSnapshot = try await branch(projectID: projectID, branchID: branchID)
        } catch {
            report(error)
        }
    }

    func applyWorkspaceFastForwardPlot(
        chapterID: NovelChapterID,
        title: String,
        content: String
    ) async -> String? {
        guard let projectID = selectedProjectID, let branchID = selectedBranchID else {
            return "当前没有打开的小说项目。"
        }
        do {
            try await creation.applyWorkspaceFastForwardPlot(
                projectID: projectID,
                branchID: branchID,
                chapterID: chapterID,
                chapterTitle: title,
                chapterContent: content
            )
            errorMessage = nil
            return nil
        } catch {
            report(error)
            return errorMessage ?? error.localizedDescription
        }
    }

    func exportWorkspace() async -> NovelWorkspaceExportArtifact? {
        guard let projectID = selectedProjectID else { return nil }
        do {
            guard case .workspace(let artifact) = try await creation.snapshot(
                .workspace(projectID)
            ) else {
                throw NovelError.invalidInput("The workspace export returned an unexpected snapshot.")
            }
            errorMessage = nil
            return artifact
        } catch {
            report(error)
            return nil
        }
    }

}
