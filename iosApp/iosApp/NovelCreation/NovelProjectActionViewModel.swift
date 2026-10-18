import Foundation
import Observation
import UIKit

extension NovelCreationViewModel {
    @discardableResult
    func refreshCurrentSelection(
        projectID: NovelProjectID? = nil,
        refreshProjectList: Bool = true,
        fallbackProjectListOnMiss: Bool = true
    ) async throws -> Bool {
        let targetProjectID = projectID ?? selectedProjectID
        guard let targetProjectID else { return false }
        if refreshProjectList {
            _ = try await refreshProjectListIfLatest()
        }
        guard selectedProjectID == targetProjectID else {
            if !refreshProjectList, fallbackProjectListOnMiss {
                _ = try await refreshProjectListIfLatest()
            }
            return false
        }
        let didReloadSelection = try await reloadSelection(
            projectID: targetProjectID,
            branchID: selectedBranchID
        )
        guard didReloadSelection else {
            if !refreshProjectList, fallbackProjectListOnMiss {
                _ = try await refreshProjectListIfLatest()
            }
            return false
        }
        guard let snapshot = projectSnapshot,
              snapshot.project.id == targetProjectID else {
            if !refreshProjectList, fallbackProjectListOnMiss {
                _ = try await refreshProjectListIfLatest()
            }
            return false
        }
        guard patchProjectSummary(from: snapshot) else {
            if !refreshProjectList, fallbackProjectListOnMiss {
                _ = try await refreshProjectListIfLatest()
                return true
            }
            return false
        }
        if reloadNoticeProjectID == targetProjectID {
            clearReloadRequirement()
        }
        return true
    }

    @discardableResult
    func renameProject(_ name: String) async -> Bool {
        guard let snapshot = projectSnapshot else { return false }
        return await perform(.renameProject(NovelRenameProjectCommand(
            context: mutationContext(projectRevision: snapshot.project.revision),
            projectID: snapshot.project.id,
            name: name
        )))
    }

    @discardableResult
    func stopActiveRunsForProjectOperation(projectID: NovelProjectID) async -> Bool {
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else {
            report(NovelError.projectBusy(projectID))
            return false
        }
        errorMessage = nil
        defer { releaseOperation(ownerID: ownerID) }

        do {
            let snapshot = try await project(id: projectID)
            var running = snapshot.activeRuns.filter { $0.status == .running }
            if quickStartStartingProjectID == projectID,
               let startingRun = quickStartStartingRun,
               !running.contains(where: { $0.id == startingRun.id }) {
                running.append(startingRun)
            }
            for run in running {
                try await interruptSessionRun(NovelCancelRunCommand(
                    context: NovelMutationContext(
                        operationID: NovelOperationID(),
                        expectedProjectRevision: nil,
                        expectedConfigRevision: nil,
                        expectedBranchHeadRevision: nil
                    ),
                    projectID: projectID,
                    runID: run.id,
                    reason: .user
                ))
            }

            let refreshed: NovelProjectSnapshot
            if selectedProjectID == projectID {
                try await refreshCurrentSelection(projectID: projectID)
                guard let projectSnapshot, projectSnapshot.project.id == projectID else {
                    throw NovelError.projectNotFound(projectID)
                }
                refreshed = projectSnapshot
            } else {
                refreshed = try await project(id: projectID)
            }
            guard !refreshed.activeRuns.contains(where: { $0.status == .running }),
                  !refreshed.branches.contains(where: { $0.activeRunID != nil }) else {
                throw NovelError.projectBusy(projectID)
            }
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteProject() async {
        guard let snapshot = projectSnapshot else { return }
        await deleteProject(
            id: snapshot.project.id,
            expectedRevision: snapshot.project.revision
        )
    }

    func deleteProject(_ project: NovelProjectSummary) async {
        if project.loadError == nil {
            guard projectSnapshot?.project.id == project.id else { return }
            await deleteProject()
            return
        }
        await deleteProject(id: project.id, expectedRevision: project.revision)
    }

    private func deleteProject(id projectID: NovelProjectID, expectedRevision: Int64) async {
        let succeeded = await perform(.deleteProject(NovelDeleteProjectCommand(
            context: mutationContext(projectRevision: expectedRevision),
            projectID: projectID
        )), reload: false)
        guard succeeded else { return }
        if selectedProjectID == projectID { clearSelection() }
        projects.removeAll { $0.id == projectID }
        await loadProjects(restoresSelection: false)
    }

    func restorePreviousProject() async {
        guard let snapshot = projectSnapshot,
              snapshot.access != .readWrite else { return }
        _ = await perform(.restorePreviousProject(NovelRestorePreviousProjectCommand(
            context: mutationContext(projectRevision: snapshot.project.revision),
            projectID: snapshot.project.id
        )))
    }

    func saveMaterial(
        materialID: NovelMaterialID?,
        kind: NovelMaterialKind,
        title: String,
        content: String,
        tags: [String],
        injectionMode: NovelInjectionMode,
        aliases: [String] = [],
        refreshProjectList: Bool = true
    ) async {
        guard let snapshot = projectSnapshot else { return }
        _ = await perform(.reviseMaterial(NovelReviseMaterialCommand(
            context: mutationContext(configRevision: snapshot.project.configRevision),
            projectID: snapshot.project.id,
            materialID: materialID ?? NovelMaterialID(),
            revisionID: NovelMaterialRevisionID(),
            kind: kind,
            title: title,
            content: content,
            tags: tags,
            injectionMode: injectionMode,
            aliases: aliases
        )), refreshProjectList: refreshProjectList)
    }

    @discardableResult
    func clarifyCharacterIdentity(
        mention: String,
        clarification: String,
        refreshProjectList: Bool = true
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot else { return false }
        return await perform(.clarifyCharacterIdentity(
            NovelClarifyCharacterIdentityCommand(
                context: mutationContext(
                    projectRevision: project.project.revision,
                    branchHeadRevision: branch.branch.headRevision
                ),
                projectID: project.project.id,
                branchID: branch.branch.id,
                checkpointID: NovelCheckpointID(),
                stateSnapshotID: NovelStateSnapshotID(),
                mention: mention,
                clarification: clarification
            )
        ), refreshProjectList: refreshProjectList)
    }

    func deleteMaterial(_ materialID: NovelMaterialID) async {
        guard let snapshot = projectSnapshot,
              !pendingMaterialDeletionIDs.contains(materialID) else { return }
        pendingMaterialDeletionIDs.insert(materialID)
        defer { pendingMaterialDeletionIDs.remove(materialID) }
        _ = await perform(.deleteMaterial(NovelDeleteMaterialCommand(
            context: mutationContext(configRevision: snapshot.project.configRevision),
            projectID: snapshot.project.id,
            materialID: materialID
        )))
    }

    @discardableResult
    func setModelPolicy(
        _ policy: NovelProjectModelPolicy,
        for purpose: NovelModelRole = .creation
    ) async -> Bool {
        guard let snapshot = projectSnapshot else { return false }
        return await perform(.setModelPolicy(NovelSetModelPolicyCommand(
            context: mutationContext(configRevision: snapshot.project.configRevision),
            projectID: snapshot.project.id,
            purpose: purpose,
            policy: policy
        )))
    }

    @discardableResult
    func setPolishPreference(_ preference: String) async -> Bool {
        guard let snapshot = projectSnapshot else { return false }
        return await perform(.setPolishPreference(NovelSetPolishPreferenceCommand(
            context: mutationContext(configRevision: snapshot.project.configRevision),
            projectID: snapshot.project.id,
            preference: preference
        )))
    }

    func ghostwriteReadinessIssues(
        requireChapterPlan: Bool = false
    ) -> [NovelGhostwriteReadinessIssue] {
        guard let project = projectSnapshot,
              let branchID = selectedBranchID else { return [.branchNeedsSync] }
        return NovelGhostwriteReadiness.issues(
            materials: project.materials,
            materialRevisions: project.materialRevisions,
            branches: project.branches,
            pendingOperations: project.pendingOperations,
            polishTransactions: project.polishTransactions,
            activeRuns: project.activeRuns,
            chapterPlans: project.chapterPlans,
            stateSnapshots: project.stateSnapshots,
            mainBranchID: project.project.mainBranchID,
            branchID: branchID,
            requireChapterPlan: requireChapterPlan
        )
    }

    @discardableResult
    func setCollaborationMode(
        _ mode: NovelCollaborationMode,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branchID = selectedBranchID else { return false }
        return await perform(.setCollaborationMode(NovelSetCollaborationModeCommand(
            context: mutationContext(
                configRevision: project.project.configRevision, approvalResponse: approvalResponse
            ),
            projectID: project.project.id,
            branchID: branchID,
            mode: mode
        )))
    }

    func setPauseGhostwriteOnBlockingContinuity(_ enabled: Bool) async -> Bool {
        guard let project = projectSnapshot else { return false }
        return await perform(.setPauseGhostwriteOnBlockingContinuity(
            NovelSetPauseGhostwriteOnBlockingContinuityCommand(
                context: mutationContext(configRevision: project.project.configRevision),
                projectID: project.project.id,
                enabled: enabled
            )
        ))
    }

    @discardableResult
    func upsertChapterPlan(
        planID: NovelChapterPlanID? = nil,
        status: NovelChapterPlanStatus,
        outlinePlacement: String,
        goalAndConflict: String,
        mustHappen: [String],
        mustNotHappen: [String],
        endingHook: String,
        visibleFacts: [String],
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branchID = selectedBranchID else { return false }
        let resolvedPlanID = planID
            ?? project.chapterPlan(for: branchID)?.id
            ?? NovelChapterPlanID()
        return await perform(.upsertChapterPlan(NovelUpsertChapterPlanCommand(
            context: mutationContext(
                configRevision: project.project.configRevision, approvalResponse: approvalResponse
            ),
            projectID: project.project.id,
            branchID: branchID,
            planID: resolvedPlanID,
            status: status,
            outlinePlacement: outlinePlacement,
            goalAndConflict: goalAndConflict,
            mustHappen: mustHappen,
            mustNotHappen: mustNotHappen,
            endingHook: endingHook,
            visibleFacts: visibleFacts
        )))
    }

    @discardableResult
    func saveChapterPlanDraft(
        projectID: NovelProjectID,
        branchID: NovelBranchID,
        outlinePlacement: String,
        goalAndConflict: String,
        mustHappen: [String],
        mustNotHappen: [String],
        endingHook: String,
        visibleFacts: [String],
        retainingDraft: Bool = true
    ) async -> Bool {
        let draft = NovelChapterPlanDraft(
            outlinePlacement: outlinePlacement, goalAndConflict: goalAndConflict,
            mustHappen: mustHappen, mustNotHappen: mustNotHappen,
            endingHook: endingHook, visibleFacts: visibleFacts
        )
        if retainingDraft {
            retainChapterPlanDraft(draft, projectID: projectID, branchID: branchID)
        }
        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else {
            report(NovelError.projectBusy(projectID))
            return false
        }
        defer { releaseOperation(ownerID: ownerID) }
        do {
            // The sheet may have disappeared while an earlier save finished.
            // Read the source project's current version instead of UI selection.
            let source = try await project(id: projectID)
            let action = NovelAction.upsertChapterPlan(NovelUpsertChapterPlanCommand(
                context: mutationContext(configRevision: source.project.configRevision),
                projectID: projectID,
                branchID: branchID,
                planID: source.chapterPlan(for: branchID)?.id ?? NovelChapterPlanID(),
                status: .draft,
                outlinePlacement: outlinePlacement,
                goalAndConflict: goalAndConflict,
                mustHappen: mustHappen,
                mustNotHappen: mustNotHappen,
                endingHook: endingHook,
                visibleFacts: visibleFacts
            ))
            let reloadSourceSelection = selectedProjectID == projectID
            let saved = await perform(
                action,
                reload: reloadSourceSelection,
                refreshProjectList: false,
                reservedOwnerID: ownerID
            )
            if saved, !reloadSourceSelection {
                await refreshProjectSummaryAfterMutation(
                    projectID: projectID,
                    selectionReloaded: false
                )
            }
            if saved {
                clearChapterPlanDraft(ifMatching: draft, projectID: projectID, branchID: branchID)
            }
            return saved
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func clearChapterPlan(branchID: NovelBranchID? = nil) async -> Bool {
        guard let project = projectSnapshot,
              let branchID = branchID ?? selectedBranchID else { return false }
        return await perform(.clearChapterPlan(NovelClearChapterPlanCommand(
            context: mutationContext(configRevision: project.project.configRevision),
            projectID: project.project.id,
            branchID: branchID
        )))
    }

    @discardableResult
    func upsertUpcomingArc(
        beats: [String],
        branchID: NovelBranchID? = nil,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branchID = branchID ?? selectedBranchID else { return false }
        return await perform(.upsertUpcomingArc(NovelUpsertUpcomingArcCommand(
            context: mutationContext(
                configRevision: project.project.configRevision, approvalResponse: approvalResponse
            ),
            projectID: project.project.id,
            branchID: branchID,
            beats: beats
        )))
    }

    @discardableResult
    func clearUpcomingArc(branchID: NovelBranchID? = nil) async -> Bool {
        guard let project = projectSnapshot,
              let branchID = branchID ?? selectedBranchID else { return false }
        return await perform(.clearUpcomingArc(NovelClearUpcomingArcCommand(
            context: mutationContext(configRevision: project.project.configRevision),
            projectID: project.project.id,
            branchID: branchID
        )))
    }

    @discardableResult
    func resolveProposal(
        _ proposalID: NovelProposalID,
        resolution: NovelSettingProposalResolution
    ) async -> Bool {
        guard let project = projectSnapshot, let branch = branchSnapshot else { return false }
        let isRejecting: Bool
        if case .reject = resolution {
            guard !pendingSettingProposalIDs.contains(proposalID) else { return false }
            pendingSettingProposalIDs.insert(proposalID)
            isRejecting = true
        } else {
            isRejecting = false
        }
        defer {
            if isRejecting { pendingSettingProposalIDs.remove(proposalID) }
        }
        return await perform(.resolveSettingProposal(NovelResolveSettingProposalCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            proposalID: proposalID,
            resolution: resolution
        )))
    }

    @discardableResult
    func rejectActiveSettingProposals() async -> Bool {
        guard canMutate,
              let project = projectSnapshot,
              let branch = branchSnapshot else { return false }
        let ids = branch.activeSettingProposals.map(\.id)
        guard !ids.isEmpty else { return true }

        let ownerID = UUID()
        guard acquireOperation(ownerID: ownerID) else { return false }
        pendingSettingProposalIDs.formUnion(ids)
        isRejectingAllSettingProposals = true
        let startingSelectionToken = selectionToken
        defer {
            pendingSettingProposalIDs.subtract(ids)
            isRejectingAllSettingProposals = false
            releaseOperation(ownerID: ownerID)
        }

        var nextProjectRevision = project.project.revision
        var nextConfigRevision = project.project.configRevision
        var mutationError: Error?
        for id in ids {
            let context = mutationContext(
                projectRevision: nextProjectRevision,
                configRevision: nextConfigRevision,
                branchHeadRevision: branch.branch.headRevision
            )
            let command = NovelResolveSettingProposalCommand(
                context: context,
                projectID: project.project.id,
                proposalID: id,
                resolution: .reject
            )
            ownMutationOperationIDs.insert(context.operationID)
            do {
                let outcome = try await creation.perform(.resolveSettingProposal(command))
                guard case let .settingProposalRejected(
                    projectID,
                    proposalID,
                    projectRevision,
                    configRevision
                ) = outcome,
                      projectID == project.project.id,
                      proposalID == id else {
                    throw NovelError.repositoryFailure(
                        "The proposal rejection returned an unexpected result."
                    )
                }
                nextProjectRevision = projectRevision
                nextConfigRevision = configRevision
            } catch {
                ownMutationOperationIDs.remove(context.operationID)
                mutationError = error
                break
            }
        }

        var reloadError: Error?
        if selectionToken == startingSelectionToken,
           selectedProjectID == project.project.id {
            do {
                let reloaded = try await reloadSelection(
                    projectID: project.project.id,
                    branchID: branch.branch.id
                )
                if !reloaded {
                    reloadError = NovelError.projectBusy(project.project.id)
                } else if let refreshed = projectSnapshot,
                          !patchProjectSummary(from: refreshed) {
                    _ = try await refreshProjectListIfLatest()
                }
            } catch {
                reloadError = error
            }
        }

        if let mutationError {
            report(mutationError)
            if let reloadError {
                reloadNoticeMessage = "拒绝建议时部分写入失败，且项目刷新失败：\(errorDescription(reloadError))"
                reloadNoticeProjectID = project.project.id
                reloadNoticeBranchID = branch.branch.id
            }
            return false
        }
        if let reloadError {
            errorMessage = nil
            reloadNoticeMessage = "拒绝建议已提交，但项目重新载入失败：\(errorDescription(reloadError))"
            reloadNoticeProjectID = project.project.id
            reloadNoticeBranchID = branch.branch.id
            return false
        }
        errorMessage = nil
        return true
    }

    func setMainBranch(_ branchID: NovelBranchID) async {
        guard let project = projectSnapshot else { return }
        _ = await perform(.setMainBranch(NovelSetMainBranchCommand(
            context: mutationContext(projectRevision: project.project.revision),
            projectID: project.project.id,
            branchID: branchID
        )))
    }

    func renameBranch(_ branchID: NovelBranchID, name: String) async {
        guard let project = projectSnapshot,
              let branch = project.branches.first(where: { $0.id == branchID }) else { return }
        _ = await perform(.renameBranch(NovelRenameBranchCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                branchHeadRevision: branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branchID,
            name: name
        )))
    }

    @discardableResult
    func forkBranch(
        from sourceBranchID: NovelBranchID,
        checkpointID: NovelCheckpointID,
        name: String
    ) async -> NovelBranchID? {
        guard let project = projectSnapshot,
              let source = project.branches.first(where: { $0.id == sourceBranchID }) else { return nil }
        let branchID = NovelBranchID()
        guard await perform(.forkBranch(NovelForkBranchCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: source.headRevision
            ),
            projectID: project.project.id,
            sourceBranchID: sourceBranchID,
            checkpointID: checkpointID,
            branchID: branchID,
            sessionID: NovelSessionID(),
            name: name
        )), selectingBranch: branchID),
              selectedBranchID == branchID,
              branchSnapshot?.branch.id == branchID else { return nil }
        return branchID
    }

    func deleteBranch(_ branchID: NovelBranchID) async {
        guard let project = projectSnapshot,
              let branch = project.branches.first(where: { $0.id == branchID }) else { return }
        _ = await perform(.deleteBranch(NovelDeleteBranchCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                branchHeadRevision: branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branchID
        )), selectingBranch: project.project.mainBranchID)
    }

    func undoBranchHead() async {
        guard let project = projectSnapshot, let branch = branchSnapshot else { return }
        _ = await perform(.undoBranchHead(NovelUndoBranchHeadCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            expectedWorkingRevision: branch.branch.workingRevision
        )))
    }

    func revertRecentChapters(
        _ proposal: NovelManuscriptRevertProposal,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot else {
            errorMessage = "项目尚未就绪，请重新载入后再试。"
            return false
        }
        switch NovelBranchSemantics.recentChapterRevertPlan(
            chapterCount: proposal.chapterCount,
            branch: branch.branch,
            chapters: project.chapters,
            chapterVersions: project.chapterVersions,
            checkpoints: project.checkpoints
        ) {
        case .failure(let failure):
            errorMessage = failure.localizedDescription
            return false
        case .success(let plan):
            guard branch.branch.headRevision == proposal.expectedHeadRevision,
                  branch.branch.workingRevision == proposal.expectedWorkingRevision,
                  plan.targetCheckpointID == proposal.targetCheckpointID,
                  plan.chapters.map(\.chapterID) == proposal.chapterIDs else {
                errorMessage = "当前分支已经变化，请重新发起回退。"
                return false
            }
            for step in 1...plan.undoStepCount {
                guard let currentProject = projectSnapshot,
                      let currentBranch = branchSnapshot else {
                    if step > 1 {
                        await reconcileGhostwriteProgressAfterRevert()
                    }
                    errorMessage = "回退进行到第 \(step) 步时项目不可用。"
                    return false
                }
                let undone = await perform(.undoBranchHead(NovelUndoBranchHeadCommand(
                    context: mutationContext(
                        projectRevision: currentProject.project.revision,
                        branchHeadRevision: currentBranch.branch.headRevision,
                        approvalResponse: step == plan.undoStepCount ? approvalResponse : nil
                    ),
                    projectID: currentProject.project.id,
                    branchID: currentBranch.branch.id,
                    expectedWorkingRevision: currentBranch.branch.workingRevision
                )))
                if !undone {
                    if step > 1 {
                        await reconcileGhostwriteProgressAfterRevert()
                        if let existing = errorMessage, !existing.isEmpty {
                            errorMessage = "已回退 \(step - 1)/\(plan.undoStepCount) 步后失败：\(existing)"
                        }
                    }
                    return false
                }
            }
            await reconcileGhostwriteProgressAfterRevert()
            return true
        }
    }

    private func reconcileGhostwriteProgressAfterRevert() async {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              let record = try? await creation.loadGhostwriteBatchProgress(
                projectID: project.project.id,
                branchID: branch.branch.id
              ) else {
            return
        }
        let reconciled = record.reconciledAfterManuscriptRevert(
            chapterVersions: project.chapterVersions,
            workingChapterIDs: Set(
                NovelBranchSemantics.workingManuscriptChapters(
                    branch: branch.branch,
                    chapters: project.chapters,
                    chapterVersions: project.chapterVersions
                ).map(\.chapterID)
            ),
            now: Date()
        )
        guard reconciled != record else { return }
        try? await creation.saveGhostwriteBatchProgress(reconciled)
    }

    @discardableResult
    func setBranchMaterialOverride(
        materialID: NovelMaterialID,
        change: NovelBranchMaterialOverrideChange
    ) async -> Bool {
        guard canMutate,
              let project = projectSnapshot,
              let branch = branchSnapshot else { return false }
        return await perform(.setBranchMaterialOverride(NovelSetBranchMaterialOverrideCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            materialID: materialID,
            change: change
        )))
    }

    /// 标记废弃 / 恢复整章。不删除任何记录,废弃后该章不再进入生成上下文。
    @discardableResult
    func setChapterDiscarded(_ isDiscarded: Bool, chapterID: NovelChapterID) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              let chapter = project.chapters.first(where: { $0.id == chapterID }) else {
            errorMessage = "章节已经不存在，请重新载入项目。"
            return false
        }
        if (chapter.discardedAt != nil) == isDiscarded { return true }
        let context = mutationContext(
            projectRevision: project.project.revision,
            branchHeadRevision: branch.branch.headRevision
        )
        if isDiscarded {
            return await perform(.discardChapter(NovelDiscardChapterCommand(
                context: context,
                projectID: project.project.id,
                branchID: branch.branch.id,
                chapterID: chapterID
            )))
        }
        return await perform(.restoreChapter(NovelRestoreChapterCommand(
            context: context,
            projectID: project.project.id,
            branchID: branch.branch.id,
            chapterID: chapterID
        )))
    }

    /// 从当前分支正文目录删除一章（工作稿不再包含；历史检查点仍保留引用）。
    func deleteChapterFromManuscript(
        chapterID: NovelChapterID,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot else {
            errorMessage = "项目尚未就绪，请重新载入后再试。"
            return false
        }
        guard project.chapters.contains(where: { $0.id == chapterID }) else {
            errorMessage = "章节已经不存在，请重新载入项目。"
            return false
        }
        guard branch.chapterSelections.contains(where: { $0.chapterID == chapterID }) else {
            errorMessage = "这一章已经不在当前正文目录里。"
            return false
        }
        let deleted = await perform(.deleteChapterFromManuscript(NovelDeleteChapterFromManuscriptCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                branchHeadRevision: branch.branch.headRevision,
                approvalResponse: approvalResponse
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            chapterID: chapterID,
            expectedWorkingRevision: branch.branch.workingRevision
        )))
        if deleted {
            do {
                try await creation.applyWorkspacePlotRelink(
                    projectID: project.project.id,
                    branchID: branch.branch.id
                )
                errorMessage = nil
            } catch {
                report(error)
            }
        }
        return deleted
    }

    func restoreChapterVersion(_ targetVersionID: NovelChapterVersionID) async {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              project.chapterVersions.contains(where: { $0.id == targetVersionID }) else {
            return
        }
        _ = await perform(.restoreChapterVersion(NovelRestoreChapterVersionCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                branchHeadRevision: branch.branch.headRevision
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            targetChapterVersionID: targetVersionID,
            proposedChapterVersionID: NovelChapterVersionID(),
            checkpointID: NovelCheckpointID(),
            expectedWorkingRevision: branch.branch.workingRevision
        )))
    }

    @discardableResult
    func saveManualRewrite(from version: NovelChapterVersionRecord) async -> Bool {
        guard let branch = branchSnapshot,
              version.chapterID == branch.chapterSelections.first(where: {
                  $0.chapterID == version.chapterID
              })?.chapterID else {
            return false
        }
        return await saveManualRewrite(
            chapterID: version.chapterID,
            title: version.title,
            content: version.content
        )
    }

    @discardableResult
    func saveManualRewrite(
        chapterID: NovelChapterID,
        title: String,
        content: String,
        approvalResponse: NovelAskUserResponse? = nil
    ) async -> Bool {
        guard let project = projectSnapshot,
              let branch = branchSnapshot,
              branch.chapterSelections.contains(where: { $0.chapterID == chapterID }) else {
            return false
        }
        // Contract v1.1 D-B: the creation actor commits the edit and its
        // plot module atomically; no separate plot-pointer follow-up.
        return await perform(.saveManualEdit(NovelSaveManualEditCommand(
            context: mutationContext(
                projectRevision: project.project.revision,
                configRevision: project.project.configRevision,
                branchHeadRevision: branch.branch.headRevision,
                approvalResponse: approvalResponse
            ),
            projectID: project.project.id,
            branchID: branch.branch.id,
            chapterID: chapterID,
            versionID: NovelChapterVersionID(),
            title: title,
            content: content,
            factCompatibilityID: UUID(),
            expectedWorkingRevision: branch.branch.workingRevision
        )))
    }

}
