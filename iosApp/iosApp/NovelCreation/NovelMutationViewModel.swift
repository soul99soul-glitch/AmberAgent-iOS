import Foundation
import Observation
import UIKit

extension NovelCreationViewModel {
    func clearError() {
        errorMessage = nil
        reloadNoticeMessage = nil
    }

    func retryCommittedMutationReload() async {
        let ownerID = UUID()
        guard let projectID = reloadNoticeProjectID,
              acquireOperation(ownerID: ownerID) else { return }
        defer { releaseOperation(ownerID: ownerID) }
        do {
            _ = try await refreshProjectListIfLatest()
            if selectedProjectID == projectID {
                try await reloadSelection(
                    projectID: projectID,
                    branchID: reloadNoticeBranchID
                )
            } else {
                let project = try await self.project(id: projectID)
                let preferredBranchID = reloadNoticeBranchID.flatMap { preferred in
                    project.branches.contains(where: {
                        $0.id == preferred && $0.lifecycle == .active
                    }) ? preferred : nil
                }
                let branchID = preferredBranchID ?? project.branches.first(where: {
                    $0.id == project.project.mainBranchID && $0.lifecycle == .active
                })?.id ?? project.branches.first(where: { $0.lifecycle == .active })?.id
                if let branchID {
                    _ = try await branch(projectID: projectID, branchID: branchID)
                }
            }
            errorMessage = nil
            if reloadNoticeProjectID == projectID {
                clearReloadRequirement()
            }
        } catch {
            errorMessage = nil
            reloadNoticeMessage = "操作已经完成，但项目重新载入失败：\(errorDescription(error))"
        }
    }

    func presentError(_ error: Error) {
        report(error)
    }

    func perform(
        _ action: NovelAction,
        selecting projectID: NovelProjectID? = nil,
        selectingBranch branchID: NovelBranchID? = nil,
        reload: Bool = true,
        refreshProjectList: Bool = true,
        reportsError: Bool = true,
        reservedOwnerID: UUID? = nil
    ) async -> Bool {
        if let projectID, selectedProjectID != projectID, isProjectSelectionBlocked {
            report(NovelError.projectBusy(selectedProjectID ?? action.projectID))
            return false
        }
        let ownerID = reservedOwnerID ?? UUID()
        guard reloadNoticeProjectID != action.projectID else {
            if reportsError {
                errorMessage = errorDescription(NovelError.storageIndeterminate(action.projectID))
            }
            return false
        }
        if let reservedOwnerID {
            guard operationOwnerID == reservedOwnerID, isPerforming else {
                if reportsError { report(NovelError.projectBusy(action.projectID)) }
                return false
            }
        } else {
            guard acquireOperation(ownerID: ownerID) else {
                if reportsError { report(NovelError.projectBusy(action.projectID)) }
                return false
            }
        }
        let stateSyncContext = stateSyncContext(for: action)
        if let stateSyncContext {
            startStateSyncActivity(
                ownerID: ownerID,
                projectID: action.projectID,
                branchID: stateSyncContext.branchID,
                pendingID: stateSyncContext.pendingID,
                attemptOperationID: stateSyncContext.attemptOperationID
            )
        }
        let startingSelectionToken = selectionToken
        defer {
            if stateSyncContext != nil { stopStateSyncActivity(ownerID: ownerID) }
            releaseOperation(ownerID: ownerID)
        }

        do {
            ownMutationOperationIDs.insert(action.context.operationID)
            _ = try await creation.perform(action)
        } catch {
            let operationError = error
            if reload {
                if refreshProjectList {
                    _ = try? await refreshProjectListIfLatest()
                }
                let targetProjectID = projectID ?? selectedProjectID ?? action.projectID
                let shouldReloadSelection = projectID != nil ||
                    selectionToken == startingSelectionToken
                let targetExists = refreshProjectList
                    ? projects.contains(where: { $0.id == targetProjectID })
                    : selectedProjectID == targetProjectID
                var didReloadSelection = false
                if shouldReloadSelection, targetExists {
                    didReloadSelection = (try? await reloadSelection(
                        projectID: targetProjectID,
                        branchID: branchID ?? selectedBranchID
                    )) == true
                }
                if !refreshProjectList {
                    await refreshProjectSummaryAfterMutation(
                        projectID: targetProjectID,
                        selectionReloaded: didReloadSelection
                    )
                }
            } else if !reload {
                await loadProjects()
            }
            if stateSyncContext != nil {
                // Keep the real invalidInput / model detail — errorDescription alone
                // used to collapse everything to a useless short line.
                lastStateSyncOperationCause = operationError
                lastStateSyncOperationError = NovelPresentation.stateSyncFailureMessage(
                    for: operationError
                )
            }
            if reportsError { report(operationError) }
            return false
        }

        if stateSyncContext != nil {
            lastStateSyncOperationCause = nil
            lastStateSyncOperationError = nil
        }
        if reportsError { errorMessage = nil }
        guard reload else { return true }

        let targetProjectID = projectID ?? selectedProjectID ?? action.projectID
        let targetBranchID = branchID ?? selectedBranchID
        do {
            if refreshProjectList {
                _ = try await refreshProjectListIfLatest()
            }
            var didReloadSelection = false
            if projectID != nil || selectionToken == startingSelectionToken {
                didReloadSelection = try await reloadSelection(
                    projectID: targetProjectID,
                    branchID: targetBranchID
                )
            }
            if !refreshProjectList {
                await refreshProjectSummaryAfterMutation(
                    projectID: targetProjectID,
                    selectionReloaded: didReloadSelection
                )
            }
            return true
        } catch {
            errorMessage = nil
            reloadNoticeMessage = "操作已经完成，但项目重新载入失败：\(errorDescription(error))"
            reloadNoticeProjectID = targetProjectID
            reloadNoticeBranchID = targetBranchID
            if !refreshProjectList {
                await refreshProjectSummaryAfterMutation(
                    projectID: targetProjectID,
                    selectionReloaded: false
                )
            }
            return true
        }
    }

    func clearReloadRequirement() {
        reloadNoticeMessage = nil
        reloadNoticeProjectID = nil
        reloadNoticeBranchID = nil
    }

    @discardableResult
    func reloadSelection(
        projectID: NovelProjectID,
        branchID preferredBranchID: NovelBranchID?
    ) async throws -> Bool {
        let token = UUID()
        selectionToken = token
        let project = try await self.project(id: projectID)
        let branchID = preferredBranchID.flatMap { preferred in
            project.branches.contains(where: { $0.id == preferred && $0.lifecycle == .active })
                ? preferred
                : nil
        } ?? project.branches.first(where: {
            $0.id == project.project.mainBranchID && $0.lifecycle == .active
        })?.id ?? project.branches.first(where: { $0.lifecycle == .active })?.id
        let loadedBranch: NovelBranchSnapshot?
        if let branchID {
            loadedBranch = try await branch(projectID: projectID, branchID: branchID)
        } else {
            loadedBranch = nil
        }
        guard selectionToken == token else { return false }
        selectedProjectID = projectID
        projectSnapshot = project
        refreshCheckoutSidecarFailure(for: projectID)
        selectedBranchID = branchID
        branchSnapshot = loadedBranch
        if let branchID { lastSelectedBranchIDs[projectID] = branchID }
        injectionPreview = nil
        return true
    }

    func projectSummaries() async throws -> [NovelProjectSummary] {
        guard case .projects(let summaries) = try await creation.snapshot(.projects) else {
            throw NovelError.invalidInput("The project list returned an unexpected snapshot.")
        }
        return summaries
    }

    func refreshProjectListIfLatest() async throws -> Bool {
        projectListReadRevision &+= 1
        let revision = projectListReadRevision
        let refreshedProjects = try await projectSummaries()
        try Task.checkCancellation()
        guard revision == projectListReadRevision else { return false }
        updateProjectsIfChanged(refreshedProjects)
        return true
    }

    func updateProjectsIfChanged(_ refreshedProjects: [NovelProjectSummary]) {
        guard projects != refreshedProjects else { return }
        projects = refreshedProjects
    }

    func patchProjectSummary(from snapshot: NovelProjectSnapshot) -> Bool {
        let summary = NovelProjectSummary(snapshot: snapshot)
        guard let index = projects.firstIndex(where: { $0.id == summary.id }) else {
            return false
        }
        guard projects[index] != summary else { return true }
        var refreshedProjects = projects
        refreshedProjects[index] = summary
        refreshedProjects.sort(by: NovelProjectSummary.listOrder)
        projectListReadRevision &+= 1
        updateProjectsIfChanged(refreshedProjects)
        return true
    }

    func refreshProjectSummaryAfterMutation(
        projectID: NovelProjectID,
        selectionReloaded: Bool
    ) async {
        if selectionReloaded,
           let snapshot = projectSnapshot,
           snapshot.project.id == projectID,
           patchProjectSummary(from: snapshot) {
            return
        }
        _ = try? await refreshProjectListIfLatest()
    }

    func refreshCheckoutSidecarFailure(for projectID: NovelProjectID?) {
        guard let projectID,
              let root = try? NovelFileProjectRepository.defaultRootDirectory() else {
            checkoutSidecarFailure = nil
            return
        }
        let package = NovelProjectShardedStorage.packageDirectory(
            projectDirectory: root.appendingPathComponent("projects", isDirectory: true),
            projectID: projectID
        )
        let failure = NovelProjectShardedStorage.checkoutWriteFailureMessage(in: package)
        if checkoutSidecarFailure != failure {
            checkoutSidecarFailure = failure
        }
    }

    func project(id: NovelProjectID) async throws -> NovelProjectSnapshot {
        guard case .project(let snapshot) = try await creation.snapshot(.project(id)) else {
            throw NovelError.invalidInput("The project returned an unexpected snapshot.")
        }
        return snapshot
    }

    func branch(
        projectID: NovelProjectID,
        branchID: NovelBranchID
    ) async throws -> NovelBranchSnapshot {
        guard case .branch(let snapshot) = try await creation.snapshot(
            .branch(projectID: projectID, branchID: branchID)
        ) else {
            throw NovelError.invalidInput("The branch returned an unexpected snapshot.")
        }
        return snapshot
    }

    func rebasedBranchSnapshot(
        _ snapshot: NovelBranchSnapshot,
        onto project: NovelProjectSnapshot
    ) -> NovelBranchSnapshot {
        NovelBranchSnapshot(
            projectID: project.project.id,
            projectRevision: project.project.revision,
            configRevision: project.project.configRevision,
            branch: project.branches.first(where: { $0.id == snapshot.branch.id })
                ?? snapshot.branch,
            session: snapshot.session,
            headCheckpoint: snapshot.headCheckpoint,
            currentState: snapshot.currentState,
            chapterSelections: snapshot.chapterSelections,
            activeSettingProposals: snapshot.activeSettingProposals,
            access: project.access
        )
    }

    func clearSelection() {
        selectionToken = UUID()
        selectedProjectID = nil
        selectedBranchID = nil
        projectSnapshot = nil
        branchSnapshot = nil
        refreshCheckoutSidecarFailure(for: nil)
        injectionPreview = nil
    }

    func mutationContext(
        projectRevision: Int64? = nil,
        configRevision: Int64? = nil,
        branchHeadRevision: Int64? = nil,
        approvalResponse: NovelAskUserResponse? = nil
    ) -> NovelMutationContext {
        NovelMutationContext(
            operationID: NovelOperationID(),
            expectedProjectRevision: projectRevision,
            expectedConfigRevision: configRevision,
            expectedBranchHeadRevision: branchHeadRevision,
            approvalResponse: approvalResponse
        )
    }

    func report(_ error: Error) {
        reloadNoticeMessage = nil
        errorMessage = errorDescription(error)
    }

    func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
